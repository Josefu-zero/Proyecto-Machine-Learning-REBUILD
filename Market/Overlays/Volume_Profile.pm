# =============================================================================
# Market::Overlays::Volume_Profile
# Sección 7 de la Especificación — Renderizador del Perfil de Volumen
#
# Dibuja sobre el Canvas de precios (price_canvas):
#   - Histograma horizontal de volumen por zona de precio
#   - Línea POC  (Point of Control) — color destacado
#   - Línea VAH  (Value Area High)  — límite superior del 70%
#   - Línea VAL  (Value Area Low)   — límite inferior del 70%
#
# Tag Tk utilizado: 'vp_overlay'
# Integración: ChartEngine llama a render() tras cada request_render().
# =============================================================================

package Market::Overlays::Volume_Profile;

use strict;
use warnings;

# =============================================================================
# CONSTRUCTOR
# =============================================================================
sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},

        # --- Colores configurables ---
        color_poc        => $args{color_poc}        // '#000000',  # Black POC
        color_vah        => $args{color_vah}        // '#000000',  # Black VAH
        color_val        => $args{color_val}        // '#000000',  # Black VAL
        color_hist_up    => $args{color_hist_up}    // '#26A69A',  # Up Volume
        color_hist_down  => $args{color_hist_down}  // '#EF5350',  # Down Volume
        color_hist_va_up => $args{color_hist_va_up} // '#4FC3F7',  # Value Area Up
        color_hist_va_dn => $args{color_hist_va_dn} // '#4FC3F7',  # Value Area Down
        color_poc_node   => $args{color_poc_node}   // '#000000',  # POC Node

        # --- Parámetros de renderizado ---
        hist_width_pct   => $args{hist_width_pct}   // 0.30, # 30% del ancho del canvas
        line_width_poc   => $args{line_width_poc}   // 1,
        line_width_va    => $args{line_width_va}    // 1,
        show_histogram   => $args{show_histogram}   // 1,
        show_poc_line    => $args{show_poc_line}    // 1,
        show_va_lines    => $args{show_va_lines}    // 1,
        show_labels      => $args{show_labels}      // 0,
    };
    bless $self, $class;
    return $self;
}

# =============================================================================
# RENDER
#
# Parámetros:
#   $scale          — objeto Market::Panels::Scales (coordenadas X/Y)
#   $vp_indicator   — instancia de Market::Indicators::Volume_Profile
#   $start_idx_vp   — índice absoluto de inicio de la ventana visible
#   $visibility     — hash de flags de visibilidad del ChartEngine
# =============================================================================
sub render {
    my ($self, $scale, $vp_indicator, $start_idx_vp, $visibility) = @_;
    my $c = $self->{canvas};

    # Limpiar dibujos anteriores de este overlay
    $c->delete('vp_overlay');

    $visibility //= {};
    my $show = sub { $visibility->{$_[0]} // 1 };
    return unless $show->('volume_profile');

    my $profiles = $vp_indicator->get_profiles();
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
    my $candle_w = $scale->_drawable_width() / $visible_bars;

    # Ancho máximo que puede ocupar el histograma (columna derecha del canvas)
    my $hist_max_w   = $width * $self->{hist_width_pct};

    for my $prof (@$profiles) {
        # Calcular la posición X del perfil en la ventana visible
        my $rel_start = $prof->{start_idx} - $start_idx_vp;
        my $rel_end   = $prof->{end_idx}   - $start_idx_vp;

        my $x_start = ($rel_start - $offset_frac) * $candle_w + ($candle_w / 2);
        my $x_end   = ($rel_end   - $offset_frac) * $candle_w + ($candle_w / 2);

        # Saltar perfiles completamente fuera de la pantalla
        next if $x_end < 0 || $x_start > $width;

        # =====================================================================
        # 1. HISTOGRAMA HORIZONTAL (barras de volumen por nivel de precio)
        # =====================================================================
        if ($self->{show_histogram} && $show->('vp_histogram')) {
            my $histogram = $prof->{histogram};
            my $levels    = scalar @$histogram;
            my $max_vol   = 0;
            for my $v (@$histogram) { $max_vol = $v if $v > $max_vol; }

            next if $max_vol <= 0;

            my $tick_px = $height / ($range / $prof->{tick_size});

            for my $lvl (0 .. $levels - 1) {
                next if $histogram->[$lvl] <= 0;

                # Precio central del nivel
                my $price_low  = $prof->{range_min} + $lvl       * $prof->{tick_size};
                my $price_high = $prof->{range_min} + ($lvl + 1) * $prof->{tick_size};

                # Posición Y en el canvas
                my $y_top    = $height - (($price_high - $min_val) / $range) * $height;
                my $y_bottom = $height - (($price_low  - $min_val) / $range) * $height;

                # Clipping vertical estricto
                $y_top    = 0      if $y_top    < 0;
                $y_bottom = $height if $y_bottom > $height;
                next if $y_top >= $y_bottom;

                # Anchura de barra proporcional al volumen relativo
                my $w_up   = ($prof->{hist_up}[$lvl]   // 0) / $max_vol * $hist_max_w;
                my $w_down = ($prof->{hist_down}[$lvl] // 0) / $max_vol * $hist_max_w;

                my $bar_x2 = $x_end;
                my $mid_x  = $bar_x2 - $w_up;
                my $bar_x1 = $mid_x - $w_down;
                
                $bar_x1 = 0 if $bar_x1 < 0;
                $mid_x  = 0 if $mid_x < 0;

                my $in_va  = ($lvl >= $prof->{va_low} && $lvl <= $prof->{va_high});
                my $c_up   = $in_va ? $self->{color_hist_va_up} : $self->{color_hist_up};
                my $c_down = $in_va ? $self->{color_hist_va_dn} : $self->{color_hist_down};

                if ($lvl == $prof->{poc_lvl}) {
                    $c_up = $self->{color_poc_node};
                    $c_down = $self->{color_poc_node};
                }

                my $stipple = $in_va ? '' : 'gray50';

                if ($w_up > 0) {
                    $c->createRectangle(
                        $mid_x, $y_top, $bar_x2, $y_bottom,
                        -fill    => $c_up,
                        -outline => '',
                        -stipple => $stipple,
                        -tags    => ['vp_overlay'],
                    );
                }
                
                if ($w_down > 0) {
                    $c->createRectangle(
                        $bar_x1, $y_top, $mid_x, $y_bottom,
                        -fill    => $c_down,
                        -outline => '',
                        -stipple => $stipple,
                        -tags    => ['vp_overlay'],
                    );
                }
            }
        }

        # =====================================================================
        # 2. LÍNEA POC (Point of Control)
        # =====================================================================
        if ($self->{show_poc_line} && $show->('vp_poc') && defined $prof->{poc}) {
            my $y_poc = $height - (($prof->{poc} - $min_val) / $range) * $height;

            if ($y_poc >= 0 && $y_poc <= $height) {
                $c->createLine(
                    $x_start, $y_poc, $x_end, $y_poc,
                    -fill  => $self->{color_poc},
                    -width => $self->{line_width_poc},
                    -dash  => '-',
                    -tags  => ['vp_overlay'],
                );

                if ($self->{show_labels}) {
                    my $lbl = sprintf("POC %.5g", $prof->{poc});
                    $c->createText(
                        $x_end - 4, $y_poc - 8,
                        -text   => $lbl,
                        -fill   => $self->{color_poc},
                        -font   => 'Helvetica 8 bold',
                        -anchor => 'e',
                        -tags   => ['vp_overlay'],
                    );
                }
            }
        }

        # =====================================================================
        # 3. LÍNEA VAH (Value Area High)
        # =====================================================================
        if ($self->{show_va_lines} && $show->('vp_va') && defined $prof->{vah}) {
            my $y_vah = $height - (($prof->{vah} - $min_val) / $range) * $height;

            if ($y_vah >= 0 && $y_vah <= $height) {
                $c->createLine(
                    $x_start, $y_vah, $x_end, $y_vah,
                    -fill  => $self->{color_vah},
                    -width => $self->{line_width_va},
                    -dash  => '-',
                    -tags  => ['vp_overlay'],
                );

                if ($self->{show_labels}) {
                    my $lbl = sprintf("VAH %.5g", $prof->{vah});
                    $c->createText(
                        $x_end - 4, $y_vah - 6,
                        -text   => $lbl,
                        -fill   => $self->{color_vah},
                        -font   => 'Helvetica 8',
                        -anchor => 'e',
                        -tags   => ['vp_overlay'],
                    );
                }
            }
        }

        # =====================================================================
        # 4. LÍNEA VAL (Value Area Low)
        # =====================================================================
        if ($self->{show_va_lines} && $show->('vp_va') && defined $prof->{val}) {
            my $y_val = $height - (($prof->{val} - $min_val) / $range) * $height;

            if ($y_val >= 0 && $y_val <= $height) {
                $c->createLine(
                    $x_start, $y_val, $x_end, $y_val,
                    -fill  => $self->{color_val},
                    -width => $self->{line_width_va},
                    -dash  => '-',
                    -tags  => ['vp_overlay'],
                );

                if ($self->{show_labels}) {
                    my $lbl = sprintf("VAL %.5g", $prof->{val});
                    $c->createText(
                        $x_end - 4, $y_val + 8,
                        -text   => $lbl,
                        -fill   => $self->{color_val},
                        -font   => 'Helvetica 8',
                        -anchor => 'e',
                        -tags   => ['vp_overlay'],
                    );
                }
            }
        }
    }

    # El histograma se dibuja detrás de las velas pero delante del grid
    $c->lower('vp_overlay');
}

1;
