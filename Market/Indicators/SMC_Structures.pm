# =============================================================================
# Market::Indicators::SMC_Structures
#
# Puerto fiel de:  "Smart Money Concepts Pro [Neon]"
# Autor original:  LuxAlgo  (CC BY-NC-SA 4.0)
# v6 Pine → Perl  Proyecto-Machine-Learning-REBUILD
#
# ARQUITECTURA:
#   calculate($market_data)   — recalculo batch completo
#   get_values()              — devuelve array ref de hashrefs por vela
#
# DATOS EMITIDOS POR VELA:
#   state            => 'HH'|'HL'|'LH'|'LL'|'none'   swing macro
#   price            => float                           precio del pivote macro
#   int_state        => 'HH'|'HL'|'LH'|'LL'|'none'   swing interno (len=5)
#   int_price        => float
#   events           => [ {type,dir,is_internal,origin,price} ]
#   fvgs             => [ {type,top,bottom,start_idx,mitigated_idx} ]
#   active_fvgs      => [ ... ]     FVGs aún no mitigados hasta esta vela
#   active_obs       => [ {type,is_internal,bar_high,bar_low,bar_idx,mitigated} ]
#   trailing_top     => float       máximo trailing absoluto
#   trailing_bottom  => float       mínimo trailing absoluto
#   trailing_top_idx => int
#   trailing_bot_idx => int
#   eq_highs         => [ {level, from_idx, to_idx} ]
#   eq_lows          => [ {level, from_idx, to_idx} ]
# =============================================================================
package Market::Indicators::SMC_Structures;

use strict;
use warnings;
use List::Util qw(min max sum);
use POSIX qw(floor);

# -----------------------------------------------------------------------------
# CONSTANTES (espeja los valores por defecto del Pine Script)
# -----------------------------------------------------------------------------
use constant {
    BULLISH      =>  1,
    BEARISH      => -1,
    BULLISH_LEG  =>  1,
    BEARISH_LEG  =>  0,

    SW_LEN          => 50,    # swLenInp  - tamaño del swing macro
    INT_LEN         => 5,     # interno (hardcoded en Pine)
    ATR_LEN         => 200,   # atrLenInp
    EQ_LEN          => 3,     # eqLenInp (Confirmation Bars)
    EQ_THRESH       => 0.1,   # eqThreshInp (mult de ATR)
    INT_OB_COUNT    => 5,     # intOBCntInp
    SW_OB_COUNT     => 5,     # swOBCntInp
};

# -----------------------------------------------------------------------------
sub new {
    my ($class, %args) = @_;
    my $self = {
        sw_len       => $args{sw_len}       // SW_LEN,
        int_len      => $args{int_len}      // INT_LEN,
        atr_len      => $args{atr_len}      // ATR_LEN,
        eq_len       => $args{eq_len}       // EQ_LEN,
        eq_thresh    => $args{eq_thresh}    // EQ_THRESH,
        int_ob_count => $args{int_ob_count} // INT_OB_COUNT,
        sw_ob_count  => $args{sw_ob_count}  // SW_OB_COUNT,
        data         => [],
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------------
# ATR  -  Average True Range (Wilder's RMA)
# -----------------------------------------------------------------------------
sub _compute_atr {
    my ($self, $candles) = @_;
    my $len = $self->{atr_len};
    my $n   = scalar @$candles;
    my @atr;

    $atr[0] = $candles->[0]{high} - $candles->[0]{low};

    for my $i (1 .. $n - 1) {
        my $c  = $candles->[$i];
        my $pc = $candles->[$i - 1];
        my $tr = max($c->{high} - $c->{low},
                     abs($c->{high} - $pc->{close}),
                     abs($c->{low}  - $pc->{close}));
        if ($i < $len) {
            my $sum = 0;
            for my $j (0 .. $i) {
                my $c2  = $candles->[$j];
                my $pc2 = $j > 0 ? $candles->[$j-1] : $candles->[0];
                my $tr2 = $j == 0
                    ? $c2->{high} - $c2->{low}
                    : max($c2->{high} - $c2->{low},
                          abs($c2->{high} - $pc2->{close}),
                          abs($c2->{low}  - $pc2->{close}));
                $sum += $tr2;
            }
            $atr[$i] = $sum / ($i + 1);
        } else {
            $atr[$i] = ($atr[$i-1] * ($len - 1) + $tr) / $len;
        }
    }
    return \@atr;
}

# -----------------------------------------------------------------------------
# LEG DETECTION  (equivalente a la funcion leg() del Pine Script)
# Devuelve un array de estados: BEARISH_LEG (0) | BULLISH_LEG (1)
# -----------------------------------------------------------------------------
sub _compute_legs {
    my ($self, $candles, $size) = @_;
    my $n = scalar @$candles;
    my @leg_state;
    my $current = BEARISH_LEG;

    for my $i (0 .. $n - 1) {
        my $new_high = 0;
        my $new_low  = 0;

        if ($i >= $size) {
            my $pivot_high = $candles->[$i - $size]{high};
            my $pivot_low  = $candles->[$i - $size]{low};

            my $max_h = -1e300;
            my $min_l =  1e300;
            for my $j ($i - $size + 1 .. $i) {
                $max_h = $candles->[$j]{high} if $candles->[$j]{high} > $max_h;
                $min_l = $candles->[$j]{low}  if $candles->[$j]{low}  < $min_l;
            }
            $new_high = 1 if $pivot_high > $max_h;
            $new_low  = 1 if $pivot_low  < $min_l;
        }

        if    ($new_high) { $current = BEARISH_LEG; }
        elsif ($new_low)  { $current = BULLISH_LEG; }
        $leg_state[$i] = $current;
    }
    return \@leg_state;
}

# -----------------------------------------------------------------------------
# PIVOTES  -  extrae lista de pivotes a partir de los legs
# Devuelve array de hashrefs: { idx, price, is_high, state, detect_idx }
# -----------------------------------------------------------------------------
sub _extract_pivots {
    my ($self, $candles, $legs, $size, $is_internal) = @_;
    my $n = scalar @$legs;
    my @pivots;

    my $last_high = undef;
    my $last_low  = undef;

    for my $i (1 .. $n - 1) {
        next if $legs->[$i] == $legs->[$i - 1];

        my $is_high = ($legs->[$i] == BEARISH_LEG);

        # Buscar el extremo en la ventana justo antes del cambio de leg
        my $search_start = max(0, $i - $size * 2);
        my $search_end   = $i - 1;

        my $pivot_idx   = $search_start;
        my $pivot_price = $is_high ? $candles->[$search_start]{high}
                                   : $candles->[$search_start]{low};

        for my $j ($search_start .. $search_end) {
            if ($is_high && $candles->[$j]{high} > $pivot_price) {
                $pivot_price = $candles->[$j]{high};
                $pivot_idx   = $j;
            } elsif (!$is_high && $candles->[$j]{low} < $pivot_price) {
                $pivot_price = $candles->[$j]{low};
                $pivot_idx   = $j;
            }
        }

        # Clasificacion HH/HL/LH/LL
        my $state;
        if ($is_high) {
            if (!defined $last_high) {
                $state = 'HH';
            } else {
                $state = $pivot_price > $last_high->{price} ? 'HH' : 'LH';
            }
            $last_high = { idx => $pivot_idx, price => $pivot_price, state => $state };
        } else {
            if (!defined $last_low) {
                $state = 'HL';
            } else {
                $state = $pivot_price < $last_low->{price} ? 'LL' : 'HL';
            }
            $last_low = { idx => $pivot_idx, price => $pivot_price, state => $state };
        }

        push @pivots, {
            idx         => $pivot_idx,
            detect_idx  => $i,
            price       => $pivot_price,
            is_high     => $is_high,
            is_internal => $is_internal // 0,
            state       => $state,
            crossed     => 0,
        };
    }
    return \@pivots;
}

# -----------------------------------------------------------------------------
# BOS / CHoCH  -  deteccion de ruptura estructural
# -----------------------------------------------------------------------------
sub _detect_bos_choch {
    my ($self, $candles, $pivots, $is_internal) = @_;
    my $n = scalar @$candles;

    my @swing_highs = grep {  $_->{is_high} } @$pivots;
    my @swing_lows  = grep { !$_->{is_high} } @$pivots;

    my @events;
    my $trend = 0;

    my $active_high = undef;
    my $active_low  = undef;
    my $hi_ptr = 0;
    my $lo_ptr = 0;

    for my $i (1 .. $n - 1) {
        my $c = $candles->[$i];

        while ($hi_ptr < scalar @swing_highs
               && $swing_highs[$hi_ptr]{detect_idx} <= $i) {
            $active_high = $swing_highs[$hi_ptr];
            $hi_ptr++;
        }
        while ($lo_ptr < scalar @swing_lows
               && $swing_lows[$lo_ptr]{detect_idx} <= $i) {
            $active_low = $swing_lows[$lo_ptr];
            $lo_ptr++;
        }

        # Cruce alcista
        if (defined $active_high && !$active_high->{crossed}
            && $c->{close} > $active_high->{price})
        {
            my $type = ($trend == BEARISH) ? 'CHoCH' : 'BOS';
            push @events, {
                type        => $type,
                dir         => 'bullish',
                is_internal => $is_internal // 0,
                origin      => $active_high->{idx},
                detect_idx  => $i,
                price       => $active_high->{price},
            };
            $active_high->{crossed} = 1;
            $trend = BULLISH;
        }

        # Cruce bajista
        if (defined $active_low && !$active_low->{crossed}
            && $c->{close} < $active_low->{price})
        {
            my $type = ($trend == BULLISH) ? 'CHoCH' : 'BOS';
            push @events, {
                type        => $type,
                dir         => 'bearish',
                is_internal => $is_internal // 0,
                origin      => $active_low->{idx},
                detect_idx  => $i,
                price       => $active_low->{price},
            };
            $active_low->{crossed} = 1;
            $trend = BEARISH;
        }
    }
    return \@events;
}

# -----------------------------------------------------------------------------
# ORDER BLOCKS
# -----------------------------------------------------------------------------
sub _compute_order_blocks {
    my ($self, $candles, $events, $atr) = @_;
    my @obs;

    for my $ev (@$events) {
        my $origin_idx = $ev->{origin};
        my $break_idx  = $ev->{detect_idx};
        next if $origin_idx >= $break_idx;

        my $ob_idx   = $origin_idx;
        my $ob_price = $ev->{dir} eq 'bullish'
            ? $candles->[$origin_idx]{low}
            : $candles->[$origin_idx]{high};

        for my $j ($origin_idx .. $break_idx - 1) {
            if ($ev->{dir} eq 'bullish' && $candles->[$j]{low} < $ob_price) {
                $ob_price = $candles->[$j]{low};
                $ob_idx   = $j;
            } elsif ($ev->{dir} eq 'bearish' && $candles->[$j]{high} > $ob_price) {
                $ob_price = $candles->[$j]{high};
                $ob_idx   = $j;
            }
        }

        push @obs, {
            type         => $ev->{dir} eq 'bullish' ? 'bull_ob' : 'bear_ob',
            is_internal  => $ev->{is_internal},
            bar_high     => $candles->[$ob_idx]{high},
            bar_low      => $candles->[$ob_idx]{low},
            bar_idx      => $ob_idx,
            created_at   => $break_idx,
            mitigated    => 0,
            mitigated_at => undef,
        };
    }
    return \@obs;
}

# -----------------------------------------------------------------------------
# FAIR VALUE GAPS  (bullish FVG: low[0]>high[2], bearish FVG: high[0]<low[2])
# -----------------------------------------------------------------------------
sub _compute_fvgs {
    my ($self, $candles, $atr) = @_;
    my $n = scalar @$candles;
    my @all_fvgs;
    my @active;

    # Auto-threshold acumulativo
    my $cum_delta = 0.0;
    my @thresh;
    $thresh[0] = 0;
    for my $i (1 .. $n - 1) {
        my $pc = $candles->[$i - 1];
        my $dp = $pc->{open} > 0
            ? abs(($pc->{close} - $pc->{open}) / ($pc->{open} * 100))
            : 0;
        $cum_delta += $dp;
        $thresh[$i] = ($cum_delta / $i) * 2;
    }

    for my $i (2 .. $n - 1) {
        my $c1 = $candles->[$i - 2];
        my $c2 = $candles->[$i - 1];
        my $c3 = $candles->[$i];

        my $delta_pct = $c2->{open} > 0
            ? ($c2->{close} - $c2->{open}) / ($c2->{open} * 100)
            : 0;

        # Bullish FVG
        if ($c3->{low} > $c1->{high} && $c2->{close} > $c1->{high}
            && $delta_pct > $thresh[$i])
        {
            my $fvg = {
                type          => 'bullish_fvg',
                top           => $c3->{low},
                bottom        => $c1->{high},
                start_idx     => $i - 1,
                mitigated_idx => undef,
            };
            push @all_fvgs, $fvg;
            push @active,   $fvg;
        }
        # Bearish FVG
        elsif ($c3->{high} < $c1->{low} && $c2->{close} < $c1->{low}
               && -$delta_pct > $thresh[$i])
        {
            my $fvg = {
                type          => 'bearish_fvg',
                top           => $c1->{low},
                bottom        => $c3->{high},
                start_idx     => $i - 1,
                mitigated_idx => undef,
            };
            push @all_fvgs, $fvg;
            push @active,   $fvg;
        }

        # Mitigacion
        my @still;
        for my $fvg (@active) {
            if ($i > $fvg->{start_idx} + 1) {
                if ($fvg->{type} eq 'bullish_fvg' && $c3->{low} <= $fvg->{top}) {
                    $fvg->{mitigated_idx} = $i;
                    next;
                }
                if ($fvg->{type} eq 'bearish_fvg' && $c3->{high} >= $fvg->{bottom}) {
                    $fvg->{mitigated_idx} = $i;
                    next;
                }
            }
            push @still, $fvg;
        }
        @active = @still;
    }
    return (\@all_fvgs, \@active);
}

# -----------------------------------------------------------------------------
# EQUAL HIGHS / LOWS
# -----------------------------------------------------------------------------
sub _compute_equal_hl {
    my ($self, $candles, $pivots, $atr) = @_;
    my @eq_highs;
    my @eq_lows;

    my @sw_highs = grep {  $_->{is_high} } @$pivots;
    my @sw_lows  = grep { !$_->{is_high} } @$pivots;

    for my $k (1 .. $#sw_highs) {
        my $prev   = $sw_highs[$k - 1];
        my $curr   = $sw_highs[$k];
        my $thresh = $self->{eq_thresh} * ($atr->[$curr->{detect_idx}] // 1);
        if (abs($curr->{price} - $prev->{price}) < $thresh) {
            push @eq_highs, {
                level     => ($curr->{price} + $prev->{price}) / 2,
                from_idx  => $prev->{idx},
                to_idx    => $curr->{idx},
                detect_at => $curr->{detect_idx},
            };
        }
    }
    for my $k (1 .. $#sw_lows) {
        my $prev   = $sw_lows[$k - 1];
        my $curr   = $sw_lows[$k];
        my $thresh = $self->{eq_thresh} * ($atr->[$curr->{detect_idx}] // 1);
        if (abs($curr->{price} - $prev->{price}) < $thresh) {
            push @eq_lows, {
                level     => ($curr->{price} + $prev->{price}) / 2,
                from_idx  => $prev->{idx},
                to_idx    => $curr->{idx},
                detect_at => $curr->{detect_idx},
            };
        }
    }
    return (\@eq_highs, \@eq_lows);
}

# -----------------------------------------------------------------------------
# CALCULATE  -  punto de entrada principal (batch)
# -----------------------------------------------------------------------------
sub calculate {
    my ($self, $market_data) = @_;
    my $size = $market_data->size();
    return unless $size > 0;

    my @candles;
    for my $i (0 .. $size - 1) {
        push @candles, $market_data->get_candle($i);
    }

    # ATR
    my $atr = $self->_compute_atr(\@candles);

    # Leg detection (macro y micro)
    my $sw_legs  = $self->_compute_legs(\@candles, $self->{sw_len});
    my $int_legs = $self->_compute_legs(\@candles, $self->{int_len});

    # Pivotes
    my $sw_pivots  = $self->_extract_pivots(\@candles, $sw_legs,  $self->{sw_len},  0);
    my $int_pivots = $self->_extract_pivots(\@candles, $int_legs, $self->{int_len}, 1);

    # BOS / CHoCH
    my $sw_events  = $self->_detect_bos_choch(\@candles, $sw_pivots,  0);
    my $int_events = $self->_detect_bos_choch(\@candles, $int_pivots, 1);
    my @all_events = (@$sw_events, @$int_events);

    # Order Blocks
    my $all_obs = $self->_compute_order_blocks(\@candles, \@all_events, $atr);

    # Mitigacion de OBs (post-calculo)
    for my $ob (@$all_obs) {
        next if $ob->{mitigated};
        for my $i ($ob->{created_at} + 1 .. $size - 1) {
            my $c = $candles[$i];
            if ($ob->{type} eq 'bull_ob' && $c->{low} < $ob->{bar_low}) {
                $ob->{mitigated}    = 1;
                $ob->{mitigated_at} = $i;
                last;
            }
            if ($ob->{type} eq 'bear_ob' && $c->{high} > $ob->{bar_high}) {
                $ob->{mitigated}    = 1;
                $ob->{mitigated_at} = $i;
                last;
            }
        }
    }

    # FVGs
    my ($all_fvgs, undef) = $self->_compute_fvgs(\@candles, $atr);

    # Equal H/L (usando su propio tamaño eq_len)
    my $eq_legs   = $self->_compute_legs(\@candles, $self->{eq_len});
    my $eq_pivots = $self->_extract_pivots(\@candles, $eq_legs, $self->{eq_len}, 0);
    my ($eq_highs, $eq_lows) = $self->_compute_equal_hl(\@candles, $eq_pivots, $atr);

    # ---- Indexar por barra ----
    my %ev_by_bar;
    for my $ev (@all_events) {
        push @{ $ev_by_bar{ $ev->{detect_idx} } }, $ev;
    }

    my %sw_piv_by_bar;
    for my $p (@$sw_pivots) {
        push @{ $sw_piv_by_bar{ $p->{detect_idx} } }, $p;
    }

    my %int_piv_by_bar;
    for my $p (@$int_pivots) {
        push @{ $int_piv_by_bar{ $p->{detect_idx} } }, $p;
    }

    my %fvg_by_bar;
    for my $f (@$all_fvgs) {
        push @{ $fvg_by_bar{ $f->{start_idx} } }, $f;
    }

    my %eq_high_by_bar;
    for my $eq (@$eq_highs) {
        push @{ $eq_high_by_bar{ $eq->{detect_at} } }, $eq;
    }
    my %eq_low_by_bar;
    for my $eq (@$eq_lows) {
        push @{ $eq_low_by_bar{ $eq->{detect_at} } }, $eq;
    }

    # ---- Construir array de datos por vela ----
    $self->{data} = [];

    my $trail_top     = $candles[0]{high};
    my $trail_bot     = $candles[0]{low};
    my $trail_top_idx = 0;
    my $trail_bot_idx = 0;
    my @active_fvg_set;

    for my $i (0 .. $size - 1) {
        my $c = $candles[$i];

        # Trailing extremes
        if ($c->{high} > $trail_top) {
            $trail_top     = $c->{high};
            $trail_top_idx = $i;
        }
        if ($c->{low} < $trail_bot) {
            $trail_bot     = $c->{low};
            $trail_bot_idx = $i;
        }

        # FVGs activos
        push @active_fvg_set, @{ $fvg_by_bar{$i} // [] };
        my @still_fvg = grep {
            !defined $_->{mitigated_idx} || $_->{mitigated_idx} > $i
        } @active_fvg_set;
        @active_fvg_set = @still_fvg;

        # OBs activos (no mitigados antes de esta barra)
        my @active_obs = grep {
            $_->{created_at} <= $i
            && (!$_->{mitigated} || $_->{mitigated_at} > $i)
        } @$all_obs;

        # Swing state macro
        my ($sw_state, $sw_price) = ('none', undef);
        if (my $pvs = $sw_piv_by_bar{$i}) {
            my $p = $pvs->[-1];
            $sw_state = $p->{state};
            $sw_price = $p->{price};
        }

        # Swing state interno
        my ($int_state, $int_price) = ('none', undef);
        if (my $pvs = $int_piv_by_bar{$i}) {
            my $p = $pvs->[-1];
            $int_state = $p->{state};
            $int_price = $p->{price};
        }

        push @{ $self->{data} }, {
            state       => $sw_state,
            price       => $sw_price,
            int_state   => $int_state,
            int_price   => $int_price,
            events      => [ @{ $ev_by_bar{$i} // [] } ],
            fvgs        => [ @{ $fvg_by_bar{$i} // [] } ],
            active_fvgs => [ @active_fvg_set ],
            active_obs  => [ @active_obs ],
            trailing_top      => $trail_top,
            trailing_bottom   => $trail_bot,
            trailing_top_idx  => $trail_top_idx,
            trailing_bot_idx  => $trail_bot_idx,
            atr         => $atr->[$i],
            eq_highs    => [ @{ $eq_high_by_bar{$i} // [] } ],
            eq_lows     => [ @{ $eq_low_by_bar{$i}  // [] } ],
        };
    }
}

# -----------------------------------------------------------------------------
# INTERFAZ ESTANDAR (requerida por IndicatorManager)
# -----------------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    push @{ $self->{data} }, {
        state => 'none', price => undef,
        int_state => 'none', int_price => undef,
        events => [], fvgs => [], active_fvgs => [], active_obs => [],
        trailing_top => undef, trailing_bottom => undef,
        trailing_top_idx => undef, trailing_bot_idx => undef,
        atr => undef, eq_highs => [], eq_lows => [],
    };
}

sub calculate_batch {
    my ($self, $market_data) = @_;
    $self->calculate($market_data);
}

sub get_values {
    my ($self) = @_;
    return $self->{data};
}

sub reset {
    my ($self) = @_;
    $self->{data} = [];
}

1;