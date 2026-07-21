# =============================================================================
# Market::Indicators::ZigZag_VolumeProfile
#
# Puerto fiel del Pine Script® v6:
#   "ZigZag Volume Profile [ChartPrime]"
#   © ChartPrime — Mozilla Public License 2.0
#   https://mozilla.org/MPL/2.0/
#
# Port author: Proyecto-Machine-Learning
#
# MAPA EXACTO Pine → Perl:
# ─────────────────────────────────────────────────────────────────────────────
#   swingLength          → swing_length       (default 150)
#   volumeBinCount       → volume_bin_count   (int(10/2) = 5 por defecto)
#   volumeProfilesQty   → max_profiles       (default 15)
#   channelWidthFactor  → channel_width      (default 1.0)
#   ta.atr(200)         → _update_atr() período 200 (Wilder)
#
#   ta.highest(swingLength) → max de ventana _highs (last swing_length HIGHs)
#   ta.lowest(swingLength)  → min de ventana _lows  (last swing_length LOWs)
#
#   isBullish := true      when  high == ta.highest(swingLength)
#   isBullish := false     when  low  == ta.lowest(swingLength)
#
#   Confirmación de swing HIGH (Pine línea 107-109):
#     if high[1] == swingHigh[1] and high < swingHigh
#         barIndexHigh := bar_index[1]
#         priceHigh    := low[1]          ← ¡LOW del pivote, NO high!
#
#   Confirmación de swing LOW (Pine línea 111-113):
#     if low[1] == swingLow[1] and low > swingLow
#         barIndexLow := bar_index[1]
#         priceLow    := low[1]
#
#   drawBinLevel (Pine línea 52-68):
#     slope = (yStart - yEnd) / (endBar - startBar)   [= (startPrice - endPrice) / range]
#     for i = 0 to endBar - startBar:
#         level = endPrice + offset + slope * i        [← recorre hacia atrás: i=0 → endBar]
#         if high[i] > level and low[i] < level:
#             volumeAtLevel += volume[i]
#     → Equivalente en Perl: iterar absolute bars de endBar a startBar
#       y calcular level = endPrice + offset + slope*(endBar - abs_bar)
#
#   drawVolumeBin (Pine línea 70-83):
#     volumePercent = vol / totalVolumeBins.sum() * 100
#     fillStart = startPrice + (trendDirection ? +slope : -slope) * int(range_/100 * volumePercent)
#     Line from (startBar + int(range_/100*volumePercent), fillStart+offset)
#           to  (startBar, startPrice + offset)
#
#   POC = bin con max volumen → línea horizontal en endPrice+offset
#         extendida de endBar a endBar+15
# =============================================================================

package Market::Indicators::ZigZag_VolumeProfile;

use strict;
use warnings;
use List::Util qw(max min);

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        # Parámetros (equivalentes exactos del Pine)
        swing_length       => $args{swing_length}       // 150,
        volume_bin_count   => $args{volume_bin_count}   // 5,    # = int(10/2)
        max_profiles       => $args{max_profiles}       // 15,
        channel_width      => $args{channel_width}      // 1.0,
        atr_period         => $args{atr_period}         // 200,

        # Ventanas deslizantes para swing detection
        _highs   => [],   # últimos swing_length HIGHs
        _lows    => [],   # últimos swing_length LOWs

        # Para ATR de Wilder (período 200)
        _closes   => [],
        _tr_sum   => 0,
        _tr_count => 0,
        _atr_prev => undef,

        # Estado (var en Pine)
        _is_bullish      => undef,
        _bar_index_high  => undef,
        _price_high      => undef,   # LOW del pivote alto (Pine: priceHigh := low[1])
        _bar_index_low   => undef,
        _price_low       => undef,   # LOW del pivote bajo  (Pine: priceLow  := low[1])

        # Perfiles acumulados (máximo max_profiles, igual que SProfile en Pine)
        _profiles => [],

        # Salida por barra
        data => [],
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# INTERFAZ ESTÁNDAR — IndicatorManager
# =============================================================================

sub update_last {
    my ($self, $market_data) = @_;
    my $idx = $market_data->last_index();
    return unless defined $idx;
    my $candle = $market_data->get_candle($idx);
    return unless defined $candle;
    $self->_process_bar($idx, $candle, $market_data);
}

sub calculate_batch {
    my ($self, $market_data) = @_;
    $self->reset();
    my $size = $market_data->size();
    for my $i (0 .. $size - 1) {
        my $candle = $market_data->get_candle($i);
        $self->_process_bar($i, $candle, $market_data);
    }
}

sub get_values   { return $_[0]->{data}                  }
sub get_profiles { return [ @{ $_[0]->{_profiles} } ]    }

sub reset {
    my ($self) = @_;
    $self->{_highs}          = [];
    $self->{_lows}           = [];
    $self->{_closes}         = [];
    $self->{_tr_sum}         = 0;
    $self->{_tr_count}       = 0;
    $self->{_atr_prev}       = undef;
    $self->{_is_bullish}     = undef;
    $self->{_bar_index_high} = undef;
    $self->{_price_high}     = undef;
    $self->{_bar_index_low}  = undef;
    $self->{_price_low}      = undef;
    $self->{_profiles}       = [];
    $self->{data}            = [];
}

# =============================================================================
# ATR DE WILDER — período configurable
# Equivalente a ta.atr(200) del Pine
# =============================================================================
sub _update_atr {
    my ($self, $candle) = @_;
    my $period = $self->{atr_period};

    # True Range
    my $prev_close = @{ $self->{_closes} } ? $self->{_closes}[-1] : $candle->{close};
    push @{ $self->{_closes} }, $candle->{close};
    shift @{ $self->{_closes} } if scalar @{ $self->{_closes} } > $period + 1;

    my $tr = max(
        $candle->{high} - $candle->{low},
        abs($candle->{high} - $prev_close),
        abs($candle->{low}  - $prev_close),
    );

    my $n = $self->{_tr_count} + 1;
    $self->{_tr_count} = $n;

    my $atr;
    if ($n <= $period) {
        # Fase warm-up: media simple
        $self->{_tr_sum} += $tr;
        $atr = $self->{_tr_sum} / $n;
    } else {
        # Smoothing de Wilder: ATR = (ATR_prev*(period-1) + TR) / period
        my $prev = $self->{_atr_prev} // $tr;
        $atr = ($prev * ($period - 1) + $tr) / $period;
    }
    $self->{_atr_prev} = $atr;
    return $atr;
}

# =============================================================================
# PROCESAMIENTO POR BARRA — traducción directa del Pine
# =============================================================================
sub _process_bar {
    my ($self, $bar_idx, $candle, $market_data) = @_;

    my $h   = $candle->{high};
    my $l   = $candle->{low};
    my $len = $self->{swing_length};

    # ── 1. ATR ──────────────────────────────────────────────────────────────
    my $atr       = $self->_update_atr($candle);
    my $atr_range = $atr * $self->{channel_width};   # Pine: atrRange

    # ── 2. Ventanas de swing (ta.highest / ta.lowest) ────────────────────
    #   Push BEFORE reading window max/min (Pine executes top-to-bottom)
    push @{ $self->{_highs} }, $h;
    push @{ $self->{_lows}  }, $l;
    shift @{ $self->{_highs} } if scalar @{ $self->{_highs} } > $len;
    shift @{ $self->{_lows}  } if scalar @{ $self->{_lows}  } > $len;

    my $swing_high = max(@{ $self->{_highs} });   # ta.highest(swingLength)
    my $swing_low  = min(@{ $self->{_lows}  });   # ta.lowest(swingLength)

    # ── 3. Detección de dirección (Pine línea 102-105) ───────────────────
    #   if swingHigh == high → isBullish := true
    #   if swingLow  == low  → isBullish := false
    my $prev_is_bullish = $self->{_is_bullish};

    $self->{_is_bullish} = 1 if $h == $swing_high;
    $self->{_is_bullish} = 0 if $l == $swing_low;

    my $is_bullish = $self->{_is_bullish};

    # ── 4. Confirmación de pivotes (Pine línea 107-113) ──────────────────
    #
    #   Necesitamos swingHigh[1] = max(highs window de la barra anterior).
    #   Equivale a calcular max sin el último elemento de _highs.
    #
    #   CLAVE (Pine línea 109): priceHigh := low[1]  ← LOW del pivote, NO high!
    #   CLAVE (Pine línea 113): priceLow  := low[1]  ← LOW del pivote bajo

    if (scalar @{ $self->{_highs} } >= 2) {
        # swingHigh[1]: max de la ventana sin la barra actual
        my @prev_h_window = @{ $self->{_highs} };
        pop @prev_h_window;
        my $sw_high_prev = max(@prev_h_window);
        my $high_prev    = $self->{_highs}[-2];   # high[1]
        my $low_prev     = $self->{_lows} [-2];   # low[1]

        # if high[1] == swingHigh[1] and high < swingHigh
        if ($high_prev == $sw_high_prev && $h < $swing_high) {
            $self->{_bar_index_high} = $bar_idx - 1;
            $self->{_price_high}     = $low_prev;   # ← priceHigh := low[1]
        }

        # swingLow[1]: min de la ventana sin la barra actual
        my @prev_l_window = @{ $self->{_lows} };
        pop @prev_l_window;
        my $sw_low_prev = min(@prev_l_window);

        # if low[1] == swingLow[1] and low > swingLow
        if ($low_prev == $sw_low_prev && $l > $swing_low) {
            $self->{_bar_index_low} = $bar_idx - 1;
            $self->{_price_low}     = $low_prev;    # ← priceLow := low[1]
        }
    }

    # ── 5. Cambio de tendencia → generar perfil (Pine línea 133-149) ─────
    my $trend_changed = 0;

    if (defined $is_bullish && defined $prev_is_bullish
        && $is_bullish != $prev_is_bullish)
    {
        $trend_changed = 1;

        my $bih = $self->{_bar_index_high};
        my $bip = $self->{_bar_index_low};
        my $ph  = $self->{_price_high};
        my $pl  = $self->{_price_low};

        if ($is_bullish && defined $bih && defined $bip && defined $ph && defined $pl) {
            # Pine línea 133-137: isBullish → tramo bajista completado
            # drawProfileSegment(barIndexHigh, priceHigh, barIndexLow, priceLow, not isBullish)
            #   startBar=barIndexHigh, startPrice=priceHigh
            #   endBar=barIndexLow,   endPrice=priceLow
            #   direction = not isBullish = false
            my $seg = $self->_draw_profile_segment(
                start_bar   => $bih,
                start_price => $ph,
                end_bar     => $bip,
                end_price   => $pl,
                direction   => 0,        # not isBullish = false
                atr_range   => $atr_range,
                market_data => $market_data,
                current_bar => $bar_idx,
            );
            $self->_push_profile($seg) if defined $seg;
        }
        elsif (!$is_bullish && defined $bih && defined $bip && defined $ph && defined $pl) {
            # Pine línea 142-146: not isBullish → tramo alcista completado
            # drawProfileSegment(barIndexLow, priceLow, barIndexHigh, priceHigh, isBullish)
            #   startBar=barIndexLow, startPrice=priceLow
            #   endBar=barIndexHigh,  endPrice=priceHigh
            #   direction = isBullish = false (el nuevo isBullish ya es false)
            my $seg = $self->_draw_profile_segment(
                start_bar   => $bip,
                start_price => $pl,
                end_bar     => $bih,
                end_price   => $ph,
                direction   => 0,        # isBullish (ya es false) = 0
                atr_range   => $atr_range,
                market_data => $market_data,
                current_bar => $bar_idx,
            );
            $self->_push_profile($seg) if defined $seg;
        }
    }

    $self->{data}[$bar_idx] = {
        swing_high    => $swing_high,
        swing_low     => $swing_low,
        is_bullish    => $is_bullish,
        trend_changed => $trend_changed,
        atr_range     => $atr_range,
    };
}

# =============================================================================
# drawBinLevel + drawVolumeBin → _draw_profile_segment
#
# Traducción directa de drawProfileSegment (Pine línea 118-128):
#
#   for i = volumeBinCount to -volumeBinCount      (N .. -N, paso -1)
#       drawBinLevel(atrRange * i, i, startBar, startPrice, endBar, endPrice)
#
# drawBinLevel (Pine línea 52-68):
#   yStart = startPrice + offset
#   yEnd   = endPrice   + offset
#   slope  = (yStart - yEnd) / (endBar - startBar)
#   for i = 0 to endBar - startBar:                ← i=0 → bar actual (endBar)
#       level = endPrice + offset + slope * i
#       if high[i] > level and low[i] < level:
#           volumeAtLevel += volume[i]
#
#   En Perl: iteramos de endBar hacia startBar con index absolute.
#   i_pine = endBar - abs_bar  → abs_bar = endBar - i_pine
#
# drawVolumeBin (Pine línea 70-83):
#   volumePercent = vol / sum * 100
#   Dibuja línea de (startBar + int(range/100*pct), fillStart+offset)
#                 a (startBar, startPrice+offset)
#   donde fillStart = startPrice ± slope * int(range/100*pct)
#   POC: línea en (endBar, endPrice+offset) → (endBar+15, endPrice+offset)
# =============================================================================
sub _draw_profile_segment {
    my ($self, %args) = @_;

    my $start_bar   = $args{start_bar};
    my $start_price = $args{start_price};
    my $end_bar     = $args{end_bar};
    my $end_price   = $args{end_price};
    my $direction   = $args{direction};   # Pine: trendDirection (bool)
    my $atr_range   = $args{atr_range};
    my $market_data = $args{market_data};
    my $current_bar = $args{current_bar};

    return undef unless defined $start_bar && defined $end_bar;
    return undef unless defined $start_price && defined $end_price;
    return undef if $atr_range <= 0;

    # En Pine, endBar > startBar siempre (endBar es el pivote más reciente)
    # Si por algún motivo son iguales, no hay rango
    my $range_bars = abs($end_bar - $start_bar);
    return undef if $range_bars == 0;

    # Asegurar endBar > startBar (cronológico)
    if ($end_bar < $start_bar) {
        ($start_bar,   $end_bar)   = ($end_bar,   $start_bar);
        ($start_price, $end_price) = ($end_price, $start_price);
    }
    $range_bars = $end_bar - $start_bar;

    my $bin_count  = $self->{volume_bin_count};   # Pine: volumeBinCount
    my $total_bins = $bin_count * 2 + 1;

    # Array de volúmenes (Pine: totalVolumeBins, se crea fresco cada barra)
    # Índices: Pine usa negativos → mapeamos offset_step = i in (-N .. +N)
    #   Perl array index = offset_step + bin_count  (0 .. 2*bin_count)
    my @total_vol_bins = (0) x $total_bins;

    # Pendiente del tramo (Pine: slope = (yStart - yEnd) / (endBar - startBar))
    #   yStart = startPrice + offset (pero offset cancela en la resta)
    #   slope  = (startPrice - endPrice) / range_bars
    my $slope_base = ($start_price - $end_price) / $range_bars;

    # ── Primera pasada: calcular volúmenes por bin (drawBinLevel) ─────────
    for my $offset_step (reverse -$bin_count .. $bin_count) {   # +N .. -N
        my $offset      = $atr_range * $offset_step;
        my $y_start     = $start_price + $offset;
        my $y_end       = $end_price   + $offset;
        my $slope       = ($y_start - $y_end) / $range_bars;   # = slope_base
        my $vol_at_level = 0.0;

        # Pine loop: for i = 0 to endBar - startBar
        #   level = endPrice + offset + slope * i
        #   high[i] / low[i] desde bar_index actual = current_bar
        #   → abs_bar = current_bar - i  (pero en el momento de dibujar,
        #     current_bar = el bar donde ocurrió el cambio de tendencia)
        #   Equivalencia: abs_bar = endBar - i_pine → iteramos endBar..startBar
        for my $i_pine (0 .. $range_bars) {
            my $abs_bar = $end_bar - $i_pine;   # Pine: bar_index[i] cuando current=endBar
            last if $abs_bar < $start_bar;
            last if $abs_bar < 0;

            my $c = $market_data->get_candle($abs_bar);
            next unless defined $c;

            my $level = $end_price + $offset + $slope * $i_pine;

            if ($c->{high} > $level && $c->{low} < $level) {
                $vol_at_level += ($c->{volume} // 0);
            }
        }

        my $bin_idx = $offset_step + $bin_count;   # índice Perl (0-based)
        $total_vol_bins[$bin_idx] = $vol_at_level;
    }

    # Suma y máximo del array (Pine: totalVolumeBins.sum() / .max())
    my $sum_vol = 0;
    $sum_vol += $_ for @total_vol_bins;
    my $max_vol = 0;
    $max_vol = $_ > $max_vol ? $_ : $max_vol for @total_vol_bins;

    # ── Segunda pasada: construir bins con metadatos (drawVolumeBin) ──────
    my @bins;
    my $poc_bin_idx    = 0;
    my $poc_offset_val = 0;

    for my $offset_step (reverse -$bin_count .. $bin_count) {
        my $bin_idx      = $offset_step + $bin_count;
        my $vol          = $total_vol_bins[$bin_idx];
        my $offset       = $atr_range * $offset_step;

        my $vol_pct = ($sum_vol > 0) ? ($vol / $sum_vol * 100) : 0;

        # Pine: fillStart = startPrice ± slope * int(range_/100 * volumePercent)
        my $bars_len   = int($range_bars / 100 * $vol_pct);
        my $is_poc     = ($vol == $max_vol && $max_vol > 0) ? 1 : 0;

        if ($is_poc) {
            $poc_bin_idx    = $bin_idx;
            $poc_offset_val = $offset;
        }

        push @bins, {
            offset_step  => $offset_step,
            offset_price => $offset,
            volume       => $vol,
            vol_pct      => $vol_pct,
            bars_len     => $bars_len,    # cuántas barras ocupa la barra del histograma
            is_poc       => $is_poc,
        };
    }

    # POC price: endPrice + offset_del_poc_bin (Pine línea 81)
    my $poc_price = $end_price + $poc_offset_val;

    return {
        start_bar   => $start_bar,
        start_price => $start_price,
        end_bar     => $end_bar,
        end_price   => $end_price,
        direction   => $direction,
        atr_range   => $atr_range,
        slope       => $slope_base,
        range_bars  => $range_bars,
        bins        => \@bins,
        poc_price   => $poc_price,
        poc_bin     => $poc_bin_idx,
        sum_vol     => $sum_vol,
        max_vol     => $max_vol,
    };
}

sub _push_profile {
    my ($self, $profile) = @_;
    return unless defined $profile;
    push @{ $self->{_profiles} }, $profile;
    # Pine línea 166: if SProfile.size() > volumeProfilesQty → shift
    shift @{ $self->{_profiles} }
        while scalar @{ $self->{_profiles} } > $self->{max_profiles};
}

1;
