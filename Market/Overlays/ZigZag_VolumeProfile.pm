# =============================================================================
# Market::Overlays::ZigZag_VolumeProfile
#
# Puerto visual fiel del Pine Script® v6:
#   "ZigZag Volume Profile [ChartPrime]"
#   © ChartPrime — Mozilla Public License 2.0
#   https://mozilla.org/MPL/2.0/
#
# Port author: Proyecto-Machine-Learning
#
# MAPA DE DIBUJO Pine → Tk:
# ─────────────────────────────────────────────────────────────────────────────
# Canal (showSwingChannel):
#   Pine: line.new(startBar, startPrice+offset, endBar, endPrice+offset)
#   Tk:   createLine x1(startBar),y(startPrice+offset), x2(endBar),y(endPrice+offset)
#
# Histograma (enableVolumeProfile):
#   Pine: line.new(
#           startBar + int(range_/100*volumePercent),  fillStart+offset,
#           startBar,                                   startPrice+offset,
#           width = volumebinWidth)
#   fillStart = startPrice + direction*slope * int(range_/100*pct)
#   → Línea HORIZONTAL desde startBar+bars_len hasta startBar
#     en el nivel Y de fillStart+offset
#   Tk: createLine bx1,by, bx2,by  (bx2=x(startBar), bx1=x(startBar+bars_len))
#
# POC diagonal (pocLineArray1 en Pine):
#   Pine: line.new(startBar, startPrice+offset, endBar, endPrice+offset)
#   → Igual que el canal, pero solo para el bin POC, con color poc
#
# POC horizontal extensión (pocLineArray en Pine):
#   Pine: line.new(endBar, endPrice+offset, endBar+15, endPrice+offset)
#   Tk:   línea horizontal de x(endBar) a x(endBar+15)
#
# Color de bins:
#   Pine: barColor = vol==max ? pocLineColor
#               : color.from_gradient(vol, 0, max, binColorHigh, binColorLow)
#         → gradiente de binColorHigh (vol=0) a binColorLow (vol=max)
#         (NOTA: Pine's from_gradient(val,min,max,c1,c2) devuelve c1 cuando val≈min)
#   Tk:   lerp(color_bin_high → color_bin_low, t=vol/max)
#
# Tag Tk: 'zvp_overlay'
# =============================================================================

package Market::Overlays::ZigZag_VolumeProfile;

use strict;
use warnings;

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},

        # Colores exactos del Pine (binColorLow=lime, binColorHigh=blue, poc=red)
        color_bullish   => $args{color_bullish}   // '#26a69a',   # ZigZag alcista
        color_bearish   => $args{color_bearish}   // '#ef5350',   # ZigZag bajista
        color_poc       => $args{color_poc}       // '#ef5350',   # pocLineColor=red
        color_channel   => $args{color_channel}   // '#555a6e',   # chart.fg_color 70% alpha
        color_bin_low   => $args{color_bin_low}   // '#00ff00',   # binColorLow=lime
        color_bin_high  => $args{color_bin_high}  // '#0000ff',   # binColorHigh=blue

        # Parámetros
        bin_width_px    => $args{bin_width_px}    // 5,    # volumebinWidth
        line_width      => $args{line_width}      // 2,
        poc_width       => $args{poc_width}       // 2,    # pocLineWidth
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# RENDER
# =============================================================================
sub render {
    my ($self, $scale, $zvp_indicator, $start_idx, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('zvp_overlay');

    $visibility //= {};
    my $show_zigzag   = $visibility->{zvp_zigzag}    // 1;
    my $show_channel  = $visibility->{zvp_channel}   // 1;
    my $show_hist     = $visibility->{zvp_histogram} // 1;
    my $show_poc      = $visibility->{zvp_poc}       // 1;

    return unless $show_zigzag || $show_channel || $show_hist || $show_poc;

    my $profiles = $zvp_indicator->get_profiles();
    return unless defined $profiles && @$profiles;

    my $width  = $c->width;
    my $height = $c->height;
    return if $width <= 0 || $height <= 0;

    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $range        = $max_val - $min_val;
    return if $range <= 0;

    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};
    my $candle_w     = $scale->_drawable_width() / $visible_bars;

    # ── Helpers de coordinadas ──────────────────────────────────────────────

    # Índice absoluto → X en canvas
    my $x_of = sub {
        my ($bar) = @_;
        my $rel = $bar - $start_idx;
        return $scale->index_to_center_x($rel);
    };

    # Precio → Y en canvas
    my $y_of = sub {
        my ($price) = @_;
        return $scale->value_to_y($price);
    };

    # Interpolación lineal de color #RRGGBB (Pine: color.from_gradient)
    # from_gradient(val, min, max, colorMin, colorMax) devuelve colorMin cuando val≈min
    # → t=0 → color_bin_high (vol bajo), t=1 → color_bin_low (vol alto)
    my $gradient_color = sub {
        my ($vol, $max_vol) = @_;
        return $self->{color_poc} if $max_vol <= 0;
        my $t = $vol / $max_vol;
        $t = 0 if $t < 0;
        $t = 1 if $t > 1;
        # Pine: from_gradient(vol, 0, max, binColorHigh, binColorLow)
        #   → at vol=0 → binColorHigh, at vol=max → binColorLow
        my $c1 = $self->{color_bin_high};   # bajo volumen
        my $c2 = $self->{color_bin_low};    # alto volumen
        my @r1 = (hex(substr($c1,1,2)), hex(substr($c1,3,2)), hex(substr($c1,5,2)));
        my @r2 = (hex(substr($c2,1,2)), hex(substr($c2,3,2)), hex(substr($c2,5,2)));
        return sprintf('#%02x%02x%02x',
            int($r1[0] + ($r2[0]-$r1[0]) * $t),
            int($r1[1] + ($r2[1]-$r1[1]) * $t),
            int($r1[2] + ($r2[2]-$r1[2]) * $t),
        );
    };

    # Cohen-Sutherland line clipping para evitar desbordamientos de enteros en Tk (zoom bug)
    my $clip_line = sub {
        my ($x0, $y0, $x1, $y1) = @_;
        my ($min_x, $min_y, $max_x, $max_y) = (-25000, -25000, 25000, 25000);
        my $compute_outcode = sub {
            my ($x, $y) = @_;
            my $code = 0;
            $code |= 1 if $x < $min_x; # LEFT
            $code |= 2 if $x > $max_x; # RIGHT
            $code |= 4 if $y < $min_y; # BOTTOM
            $code |= 8 if $y > $max_y; # TOP
            return $code;
        };
        my $outcode0 = $compute_outcode->($x0, $y0);
        my $outcode1 = $compute_outcode->($x1, $y1);
        my $accept = 0;
        while (1) {
            if (!($outcode0 | $outcode1)) {
                $accept = 1;
                last;
            } elsif ($outcode0 & $outcode1) {
                last;
            } else {
                my $x; my $y;
                my $outcode_out = $outcode0 ? $outcode0 : $outcode1;
                if ($outcode_out & 8) {
                    $x = $x0 + ($x1 - $x0) * ($max_y - $y0) / ($y1 - $y0);
                    $y = $max_y;
                } elsif ($outcode_out & 4) {
                    $x = $x0 + ($x1 - $x0) * ($min_y - $y0) / ($y1 - $y0);
                    $y = $min_y;
                } elsif ($outcode_out & 2) {
                    $y = $y0 + ($y1 - $y0) * ($max_x - $x0) / ($x1 - $x0);
                    $x = $max_x;
                } elsif ($outcode_out & 1) {
                    $y = $y0 + ($y1 - $y0) * ($min_x - $x0) / ($x1 - $x0);
                    $x = $min_x;
                }
                if ($outcode_out == $outcode0) {
                    $x0 = $x; $y0 = $y;
                    $outcode0 = $compute_outcode->($x0, $y0);
                } else {
                    $x1 = $x; $y1 = $y;
                    $outcode1 = $compute_outcode->($x1, $y1);
                }
            }
        }
        return $accept ? ($x0, $y0, $x1, $y1) : ();
    };

    # ── Dibujar cada perfil ─────────────────────────────────────────────────
    for my $prof (@$profiles) {
        my $sb   = $prof->{start_bar};
        my $sp   = $prof->{start_price};
        my $eb   = $prof->{end_bar};
        my $ep   = $prof->{end_price};
        my $dir  = $prof->{direction};
        my $atr  = $prof->{atr_range};
        my $rbars = $prof->{range_bars};
        my $slope = $prof->{slope};   # (startPrice - endPrice) / range_bars
        my $bins  = $prof->{bins};
        my $max_v = $prof->{max_vol} // 0;

        my $x_start = $x_of->($sb);
        my $x_end   = $x_of->($eb);

        # Skip si totalmente fuera de pantalla
        my $margin = $candle_w * 20;
        next if $x_end < -$margin && $x_start < -$margin;
        next if $x_start > $width + $margin && $x_end > $width + $margin;

        my $color_zz = (defined $prof->{direction} && !$prof->{direction})
            ? $self->{color_bearish}
            : $self->{color_bullish};

        # ── 1. LÍNEA ZIGZAG ──────────────────────────────────────────────
        if ($show_zigzag) {
            my $y1 = $y_of->($sp);
            my $y2 = $y_of->($ep);

            # Clip + dibujar sólo si al menos un extremo visible
            unless (($x_start < 0 && $x_end < 0) || ($x_start > $width && $x_end > $width)) {
                if (my @coords = $clip_line->($x_start, $y1, $x_end, $y2)) {
                    $c->createLine(
                        @coords,
                        -fill  => $color_zz,
                        -width => $self->{line_width},
                        -tags  => ['zvp_overlay'],
                    );
                }

                # Marcadores de pivote (círculos pequeños)
                for my $px_py ([$x_start, $y1], [$x_end, $y2]) {
                    my ($px, $py) = @$px_py;
                    if ($px >= -6 && $px <= $width + 6) {
                        $c->createOval(
                            $px - 4, $py - 4, $px + 4, $py + 4,
                            -fill    => $color_zz,
                            -outline => $color_zz,
                            -tags    => ['zvp_overlay'],
                        );
                    }
                }
            }
        }

        next unless defined $bins && @$bins;

        for my $bin (@$bins) {
            my $off      = $bin->{offset_price};
            my $vol      = $bin->{volume};
            my $vol_pct  = $bin->{vol_pct};
            my $bars_len = $bin->{bars_len};
            my $is_poc   = $bin->{is_poc};

            # ── 2. CANAL (showSwingChannel) ──────────────────────────────
            # Pine: line.new(startBar, startPrice+offset, endBar, endPrice+offset)
            if ($show_channel) {
                my $cy1 = $y_of->($sp + $off);
                my $cy2 = $y_of->($ep + $off);
                unless (($cy1 < 0 && $cy2 < 0) || ($cy1 > $height && $cy2 > $height)) {
                    if (my @coords = $clip_line->($x_start, $cy1, $x_end, $cy2)) {
                        $c->createLine(
                            @coords,
                            -fill  => $self->{color_channel},
                            -width => 1,
                            -tags  => ['zvp_overlay'],
                        );
                    }
                }
            }

            # ── 3. HISTOGRAMA (enableVolumeProfile) ──────────────────────
            # Pine línea 77:
            #   line.new(startBar + int(range/100*pct), fillStart+offset,
            #            startBar,                      startPrice+offset,
            #            width = volumebinWidth)
            # fillStart = startPrice + (dir ? +slope : -slope) * int(range/100*pct)
            #
            # La línea va de startBar hasta startBar+bars_len, en Y=fillStart+offset
            # Aquí startBar es el extremo inicial del tramo (more left on chart)
            if ($show_hist && $vol > 0) {
                my $bar_color = $is_poc
                    ? $self->{color_poc}
                    : $gradient_color->($vol, $max_v);

                # fillStart depende de direction:
                #   trendDirection=true  → +slope (extiende hacia endBar)
                #   trendDirection=false → -slope (extiende hacia startBar)
                # Pine: x1 = startBar + int(range/100*pct), y = fillStart + offset
                #       x2 = startBar,                      y = startPrice + offset
                # La línea es HORIZONTAL (mismo Y) dentro del canal
                my $fill_start;
                if ($dir) {
                    $fill_start = $sp + $slope * $bars_len;
                } else {
                    $fill_start = $sp - $slope * $bars_len;
                }

                # X coordenadas: de startBar a startBar+bars_len
                my $px1 = $x_of->($sb + $bars_len);
                my $px2 = $x_of->($sb);

                # Y coordenada única para dibujo horizontal (fillStart + offset)
                my $by  = $y_of->($fill_start + $off);

                unless (($px1 < 0 && $px2 < 0) || ($px1 > $width && $px2 > $width) || $by < 0 || $by > $height) {
                    if (my @coords = $clip_line->($px1, $by, $px2, $by)) {
                        $c->createLine(
                            @coords,
                            -fill  => $bar_color,
                            -width => $self->{bin_width_px},
                            -tags  => ['zvp_overlay'],
                        );
                    }
                }
            }

            # ── 4. POC LINES ─────────────────────────────────────────────
            # Pine línea 81-82:
            #   pocLineArray  → line(endBar, endPrice+offset, endBar+15, endPrice+offset)
            #   pocLineArray1 → line(startBar, startPrice+offset, endBar, endPrice+offset)
            if ($show_poc && $is_poc) {
                my $y_poc_end   = $y_of->($ep + $off);
                my $y_poc_start = $y_of->($sp + $off);

                if ($y_poc_end >= 0 && $y_poc_end <= $height) {
                    # Línea diagonal POC (startBar..endBar) = pocLineArray1
                    $c->createLine(
                        $x_start, $y_poc_start,
                        $x_end,   $y_poc_end,
                        -fill  => $self->{color_poc},
                        -width => $self->{poc_width},
                        -tags  => ['zvp_overlay'],
                    );

                    # Extensión horizontal hacia el futuro (endBar..endBar+15) = pocLineArray
                    my $x_poc_ext = $x_of->($eb + 15);
                    $c->createLine(
                        $x_end,     $y_poc_end,
                        $x_poc_ext, $y_poc_end,
                        -fill  => $self->{color_poc},
                        -width => $self->{poc_width},
                        -dash  => '-',
                        -tags  => ['zvp_overlay'],
                    );

                    # Etiqueta POC
                    if ($x_poc_ext >= -50 && $x_poc_ext <= $width + 100) {
                        my $poc_label = sprintf("POC %.5g", $ep + $off);
                        $c->createText(
                            $x_poc_ext + 4, $y_poc_end,
                            -text   => $poc_label,
                            -fill   => $self->{color_poc},
                            -font   => 'Helvetica 8 bold',
                            -anchor => 'w',
                            -tags   => ['zvp_overlay'],
                        );
                    }
                }
            }
        }
    }

    $c->lower('zvp_overlay');
}

1;
