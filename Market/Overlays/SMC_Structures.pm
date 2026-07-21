# =============================================================================
# Market::Overlays::SMC_Structures
#
# Renderer fiel del indicador "Smart Money Concepts Pro [Neon]"
# Puerto de Pine Script v6 → Perl/Tk
# Autor original: LuxAlgo (CC BY-NC-SA 4.0)
#
# PALETA NEON (por defecto):
#   Bullish : #00ffd5  (Neon Cyan)
#   Bearish : #ff3a8c  (Hot Pink)
#   Accent  : #00d4ff
#   Neutral : #aab3c8
#
# CLAVES DE VISIBILIDAD (hash $visibility):
#   bos_choch          Lineas BOS/CHoCH macro (swing)
#   int_bos_choch      Lineas BOS/CHoCH internos
#   structure_labels   Etiquetas HH/HL/LH/LL macro
#   int_structure_labels Etiquetas HH/HL/LH/LL internos
#   strong_weak_hl     Strong/Weak High & Low (trailing extremes)
#   order_blocks       Order Blocks de swing
#   int_order_blocks   Order Blocks internos
#   fvg                Fair Value Gaps
#   eq_highs_lows      Equal Highs / Lows
#   premium_discount   Zonas Premium / Equilibrium / Discount
#
# TAG Tk: 'smc_overlay'  (todos los items bajo este tag se borran en cada render)
# =============================================================================
package Market::Overlays::SMC_Structures;

use strict;
use warnings;
use utf8;

# ─────────────────────────────────────────────────────────────────────────────
# PALETA NEON
# ─────────────────────────────────────────────────────────────────────────────
my $BULL_COL      = '#00ffd5';  # Neon Cyan
my $BULL_DARK     = '#00b896';  # variante mas oscura para OBs internos
my $BEAR_COL      = '#ff3a8c';  # Hot Pink
my $BEAR_DARK     = '#b5255f';
my $ACCENT_COL    = '#00d4ff';  # Electric Blue
my $NEUTRAL_COL   = '#aab3c8';
my $BG_BULL_OB_I  = '#001a15';  # relleno OB interno bullish
my $BG_BEAR_OB_I  = '#200010';  # relleno OB interno bearish
my $BG_BULL_OB_S  = '#002a20';  # relleno OB swing bullish
my $BG_BEAR_OB_S  = '#30001a';  # relleno OB swing bearish
my $PREM_COL      = '#ff3a8c';
my $DISC_COL      = '#00ffd5';
my $EQ_COL        = '#aab3c8';
my $EQH_COL       = '#ff3a8c';
my $EQL_COL       = '#00ffd5';

# ─────────────────────────────────────────────────────────────────────────────
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
    };
    bless $self, $class;
    return $self;
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper: convierte un color hex (#RRGGBB) con un nivel de opacidad 0..1
# en una version aproximada mezclada con el fondo (#131722)
# ─────────────────────────────────────────────────────────────────────────────
sub _blend {
    my ($hex, $alpha, $bg_hex) = @_;
    $bg_hex //= '#131722';
    $alpha  //= 0.25;

    my ($fr, $fg, $fb) = (hex(substr($hex, 1, 2)),
                          hex(substr($hex, 3, 2)),
                          hex(substr($hex, 5, 2)));
    my ($br, $bg, $bb) = (hex(substr($bg_hex, 1, 2)),
                          hex(substr($bg_hex, 3, 2)),
                          hex(substr($bg_hex, 5, 2)));
    my $r = int($fr * $alpha + $br * (1 - $alpha));
    my $g = int($fg * $alpha + $bg * (1 - $alpha));
    my $b = int($fb * $alpha + $bb * (1 - $alpha));
    return sprintf('#%02x%02x%02x', $r, $g, $b);
}

# ─────────────────────────────────────────────────────────────────────────────
# render($scale, $smc_slice, $start_idx_viewport, $visibility)
# ─────────────────────────────────────────────────────────────────────────────
sub render {
    my ($self, $scale, $smc_slice, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('smc_overlay');
    return unless $smc_slice && @$smc_slice;

    $start_idx_viewport //= 0;
    $visibility         //= {};
    my $show = sub { $visibility->{$_[0]} // 1 };

    my $width        = $c->width;
    my $height       = $c->height;
    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $range        = $max_val - $min_val;
    return if $range <= 0;

    # =========================================================================
    # 1. STRONG / WEAK HIGH & LOW   (trailing extremes)
    # =========================================================================
    if ($show->('strong_weak_hl')) {
        my $last = $smc_slice->[-1];
        if (defined $last && defined $last->{trailing_top}) {
            my $top  = $last->{trailing_top};
            my $bot  = $last->{trailing_bottom};
            my $y_top = $scale->value_to_y($top);
            my $y_bot = $scale->value_to_y($bot);

            # Linea Strong High (roja/bear)
            $c->createLine(0, $y_top, $width + 2000, $y_top,
                -fill  => $BEAR_COL, -width => 1,
                -dash  => [6, 3],
                -tags  => ['smc_overlay']);
            $c->createText($width - 4, $y_top - 8,
                -text    => 'Strong High',
                -fill    => $BEAR_COL,
                -font    => 'Helvetica 8',
                -anchor  => 'e',
                -tags    => ['smc_overlay']);

            # Linea Strong Low (cyan/bull)
            $c->createLine(0, $y_bot, $width + 2000, $y_bot,
                -fill  => $BULL_COL, -width => 1,
                -dash  => [6, 3],
                -tags  => ['smc_overlay']);
            $c->createText($width - 4, $y_bot + 8,
                -text    => 'Strong Low',
                -fill    => $BULL_COL,
                -font    => 'Helvetica 8',
                -anchor  => 'e',
                -tags    => ['smc_overlay']);
        }
    }

    # =========================================================================
    # 2. PREMIUM / DISCOUNT / EQUILIBRIUM ZONES
    # =========================================================================
    if ($show->('premium_discount')) {
        my $last = $smc_slice->[-1];
        if (defined $last && defined $last->{trailing_top}) {
            my $top = $last->{trailing_top};
            my $bot = $last->{trailing_bottom};
            my $mid = ($top + $bot) / 2;

            # Premium zone (top 5%)
            my $prem_bot = $top * 0.95 + $bot * 0.05;
            my $y_top_p  = $scale->value_to_y($top);
            my $y_bot_p  = $scale->value_to_y($prem_bot);
            my $fill_p   = _blend($PREM_COL, 0.12);
            $c->createRectangle(0, $y_top_p, $width + 2000, $y_bot_p,
                -fill    => $fill_p,
                -outline => '',
                -tags    => ['smc_overlay']);
            $c->createText(4, ($y_top_p + $y_bot_p) / 2,
                -text   => 'Premium',
                -fill   => $PREM_COL,
                -font   => 'Helvetica 8 italic',
                -anchor => 'w',
                -tags   => ['smc_overlay']);

            # Equilibrium zone (central 5%)
            my $eq_top = $mid * 1.025 + $bot * (1 - 1.025);
            my $eq_bot = $bot * 1.025 + $mid * (1 - 1.025);
            $eq_top = $top * 0.525 + $bot * 0.475;
            $eq_bot = $top * 0.475 + $bot * 0.525;
            my $y_eq_top = $scale->value_to_y($eq_top);
            my $y_eq_bot = $scale->value_to_y($eq_bot);
            my $fill_e   = _blend($EQ_COL, 0.10);
            $c->createRectangle(0, $y_eq_top, $width + 2000, $y_eq_bot,
                -fill    => $fill_e,
                -outline => '',
                -tags    => ['smc_overlay']);
            $c->createText(4, ($y_eq_top + $y_eq_bot) / 2,
                -text   => 'Equilibrium',
                -fill   => $EQ_COL,
                -font   => 'Helvetica 8 italic',
                -anchor => 'w',
                -tags   => ['smc_overlay']);

            # Discount zone (bottom 5%)
            my $disc_top = $bot * 0.95 + $top * 0.05;
            my $y_top_d  = $scale->value_to_y($disc_top);
            my $y_bot_d  = $scale->value_to_y($bot);
            my $fill_d   = _blend($DISC_COL, 0.12);
            $c->createRectangle(0, $y_top_d, $width + 2000, $y_bot_d,
                -fill    => $fill_d,
                -outline => '',
                -tags    => ['smc_overlay']);
            $c->createText(4, ($y_top_d + $y_bot_d) / 2,
                -text   => 'Discount',
                -fill   => $DISC_COL,
                -font   => 'Helvetica 8 italic',
                -anchor => 'w',
                -tags   => ['smc_overlay']);
        }
    }

    # =========================================================================
    # 3. FAIR VALUE GAPS
    # =========================================================================
    if ($show->('fvg')) {
        # Recopilar FVGs activos en la primera barra visible
        my %drawn_fvg;
        my @fvgs_to_draw;

        if (@$smc_slice && exists $smc_slice->[0]{active_fvgs}) {
            push @fvgs_to_draw, @{ $smc_slice->[0]{active_fvgs} };
        }

        for my $i (0 .. $#$smc_slice) {
            my $punto = $smc_slice->[$i];
            next unless $punto && exists $punto->{fvgs};
            push @fvgs_to_draw, @{ $punto->{fvgs} };
        }

        for my $fvg (@fvgs_to_draw) {
            my $key = "$fvg->{type}:$fvg->{start_idx}";
            next if $drawn_fvg{$key}++;

            my $rel_start = $fvg->{start_idx} - $start_idx_viewport;
            my $x1 = $scale->index_to_center_x($rel_start);
            my $x2;

            if (defined $fvg->{mitigated_idx}) {
                my $rel_end = $fvg->{mitigated_idx} - $start_idx_viewport;
                next if $rel_end < 0;
                $x2 = $scale->index_to_center_x($rel_end);
            } else {
                $x2 = $width + 2000;
            }

            my $y1 = $scale->value_to_y($fvg->{top});
            my $y2 = $scale->value_to_y($fvg->{bottom});

            my $is_bull = $fvg->{type} eq 'bullish_fvg';
            my $base    = $is_bull ? $BULL_COL : $BEAR_COL;

            if (defined $fvg->{mitigated_idx}) {
                # FVG mitigado: gris tenue
                $c->createRectangle($x1, $y1, $x2, $y2,
                    -fill    => '#1e2133',
                    -outline => '#3a3f55',
                    -dash    => [2, 2],
                    -tags    => ['smc_overlay']);
            } else {
                my $fill = _blend($base, 0.18);
                my $mid_y = ($y1 + $y2) / 2;
                # Zona superior (mas opaca)
                $c->createRectangle($x1, $y1, $x2, $mid_y,
                    -fill    => _blend($base, 0.22),
                    -outline => '',
                    -tags    => ['smc_overlay']);
                # Zona inferior (mas transparente)
                $c->createRectangle($x1, $mid_y, $x2, $y2,
                    -fill    => _blend($base, 0.12),
                    -outline => '',
                    -tags    => ['smc_overlay']);
                # Borde superior (linea de precio)
                $c->createLine($x1, $y1, $x2, $y1,
                    -fill  => $base,
                    -width => 1,
                    -tags  => ['smc_overlay']);
                # Borde inferior
                $c->createLine($x1, $y2, $x2, $y2,
                    -fill  => $base,
                    -width => 1,
                    -dash  => [4, 2],
                    -tags  => ['smc_overlay']);
                # Etiqueta FVG
                $c->createText($x1 + 3, ($y1 + $y2) / 2,
                    -text   => 'FVG',
                    -fill   => $base,
                    -font   => 'Helvetica 7',
                    -anchor => 'w',
                    -tags   => ['smc_overlay']);
            }
        }
    }

    # =========================================================================
    # 4. ORDER BLOCKS
    # =========================================================================
    for my $i (0 .. $#$smc_slice) {
        my $punto = $smc_slice->[$i];
        next unless $punto && exists $punto->{active_obs};

        for my $ob (@{ $punto->{active_obs} }) {
            next if $ob->{is_internal} && !$show->('int_order_blocks');
            next if !$ob->{is_internal} && !$show->('order_blocks');

            # Solo dibujar OBs en la ULTIMA barra visible para evitar duplicados
            next unless $i == $#$smc_slice;

            my $is_bull = $ob->{type} eq 'bull_ob';
            my $is_int  = $ob->{is_internal};

            my $base_col  = $is_bull ? $BULL_COL : $BEAR_COL;
            my $fill_col  = $is_bull
                ? ($is_int ? $BG_BULL_OB_I : $BG_BULL_OB_S)
                : ($is_int ? $BG_BEAR_OB_I : $BG_BEAR_OB_S);

            my $rel_bar = $ob->{bar_idx} - $start_idx_viewport;
            my $x1 = $scale->index_to_center_x($rel_bar);
            my $x2 = $width + 2000;

            my $y1 = $scale->value_to_y($ob->{bar_high});
            my $y2 = $scale->value_to_y($ob->{bar_low});

            next if $y1 > $height || $y2 < 0;

            $c->createRectangle($x1, $y1, $x2, $y2,
                -fill    => _blend($base_col, $is_int ? 0.18 : 0.25),
                -outline => $is_int ? '' : $base_col,
                -dash    => $is_int ? [4, 2] : undef,
                -tags    => ['smc_overlay']);

            # Etiqueta
            my $lbl = ($is_bull ? 'Bull' : 'Bear') . ' OB' . ($is_int ? ' (i)' : '');
            $c->createText($x1 + 3, ($y1 + $y2) / 2,
                -text   => $lbl,
                -fill   => $base_col,
                -font   => 'Helvetica 7 bold',
                -anchor => 'w',
                -tags   => ['smc_overlay']);
        }
    }

    # =========================================================================
    # 5. EQUAL HIGHS / LOWS
    # =========================================================================
    if ($show->('eq_highs_lows')) {
        my %drawn_eq;
        for my $i (0 .. $#$smc_slice) {
            my $punto = $smc_slice->[$i];
            next unless $punto;

            for my $eq (@{ $punto->{eq_highs} // [] }) {
                my $key = "H:$eq->{from_idx}:$eq->{to_idx}";
                next if $drawn_eq{$key}++;
                my $x1  = $scale->index_to_center_x($eq->{from_idx} - $start_idx_viewport);
                my $x2  = $scale->index_to_center_x($eq->{to_idx}   - $start_idx_viewport);
                my $y   = $scale->value_to_y($eq->{level});
                my $mid_x = ($x1 + $x2) / 2;
                $c->createLine($x1, $y, $x2, $y,
                    -fill  => $EQH_COL, -width => 1,
                    -dash  => [3, 2],
                    -tags  => ['smc_overlay']);
                $c->createText($mid_x, $y - 9,
                    -text => 'EQH', -fill => $EQH_COL,
                    -font => 'Helvetica 7 bold',
                    -tags => ['smc_overlay']);
            }

            for my $eq (@{ $punto->{eq_lows} // [] }) {
                my $key = "L:$eq->{from_idx}:$eq->{to_idx}";
                next if $drawn_eq{$key}++;
                my $x1  = $scale->index_to_center_x($eq->{from_idx} - $start_idx_viewport);
                my $x2  = $scale->index_to_center_x($eq->{to_idx}   - $start_idx_viewport);
                my $y   = $scale->value_to_y($eq->{level});
                my $mid_x = ($x1 + $x2) / 2;
                $c->createLine($x1, $y, $x2, $y,
                    -fill  => $EQL_COL, -width => 1,
                    -dash  => [3, 2],
                    -tags  => ['smc_overlay']);
                $c->createText($mid_x, $y + 9,
                    -text => 'EQL', -fill => $EQL_COL,
                    -font => 'Helvetica 7 bold',
                    -tags => ['smc_overlay']);
            }
        }
    }

    # =========================================================================
    # 6. BOS / CHoCH  (macro + internos)
    # =========================================================================
    for my $i (0 .. $#$smc_slice) {
        my $punto = $smc_slice->[$i];
        next unless $punto && @{ $punto->{events} // [] };

        for my $ev (@{ $punto->{events} }) {
            my $is_int = $ev->{is_internal};

            # Filtro de visibilidad
            if ($is_int) {
                next unless $show->('int_bos_choch');
            } else {
                next unless $show->('bos_choch');
            }

            my $rel_origin = $ev->{origin} - $start_idx_viewport;
            my $rel_break  = $i;

            next if $rel_origin < -200 || $rel_break > scalar @$smc_slice + 50;

            my $x_start = $scale->index_to_center_x($rel_origin);
            my $x_end   = $scale->index_to_center_x($rel_break);
            my $y       = $scale->value_to_y($ev->{price});

            my $color = $ev->{dir} eq 'bullish' ? $BULL_COL : $BEAR_COL;

            # Linea solida (swing) o guiones (interno)
            if ($is_int) {
                $c->createLine($x_start, $y, $x_end, $y,
                    -fill  => $color, -width => 1,
                    -dash  => [4, 3],
                    -tags  => ['smc_overlay']);
            } else {
                $c->createLine($x_start, $y, $x_end, $y,
                    -fill  => $color, -width => 1.5,
                    -tags  => ['smc_overlay']);
            }

            # Etiqueta centrada
            my $mid_x = ($x_start + $x_end) / 2;
            my $lbl   = $ev->{type} . ($is_int ? ' (i)' : '');
            my $oy    = $ev->{dir} eq 'bullish' ? -9 : 9;
            my $style = $ev->{dir} eq 'bullish'
                ? 'Helvetica 8 bold' : 'Helvetica 8 bold';

            $c->createText($mid_x, $y + $oy,
                -text => $lbl, -fill => $color,
                -font => $style,
                -tags => ['smc_overlay']);
        }
    }

    # =========================================================================
    # 7. ETIQUETAS ESTRUCTURALES HH / HL / LH / LL
    # =========================================================================
    for my $i (0 .. $#$smc_slice) {
        my $punto = $smc_slice->[$i];
        next unless $punto;

        # Macro
        if ($show->('structure_labels')
            && defined $punto->{state} && $punto->{state} ne 'none')
        {
            my $x   = $scale->index_to_center_x($i);
            my $y   = $scale->value_to_y($punto->{price});
            # Highs arriba, lows abajo
            my $oy  = ($punto->{state} =~ /H$/) ? -14 : 14;
            my $col = ($punto->{state} =~ /H/) ? $BEAR_COL : $BULL_COL;

            $c->createText($x, $y + $oy,
                -text => $punto->{state},
                -fill => $col,
                -font => 'Helvetica 8 bold',
                -tags => ['smc_overlay']);
        }

        # Internos
        if ($show->('int_structure_labels')
            && defined $punto->{int_state} && $punto->{int_state} ne 'none')
        {
            my $x   = $scale->index_to_center_x($i);
            my $y   = $scale->value_to_y($punto->{int_price});
            my $oy  = ($punto->{int_state} =~ /H$/) ? -12 : 12;
            my $col = ($punto->{int_state} =~ /H/)
                ? _blend($BEAR_COL, 0.7) : _blend($BULL_COL, 0.7);

            $c->createText($x, $y + $oy,
                -text => $punto->{int_state},
                -fill => $col,
                -font => 'Helvetica 7',
                -tags => ['smc_overlay']);
        }
    }

    # Asegurar que el overlay quede debajo de las velas
    $c->lower('smc_overlay');
}

1;