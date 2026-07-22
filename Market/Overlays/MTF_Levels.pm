package Market::Overlays::MTF_Levels;

use strict;
use warnings;

use constant RIGHT_MARGIN => 70;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas        => $args{canvas},
        color_daily   => $args{color_daily}   // '#2962FF',
        color_weekly  => $args{color_weekly}  // '#FF6D00',
        color_monthly => $args{color_monthly} // '#00BCD4',
        style_daily   => $args{style_daily}   // 'SOLID',
        style_weekly  => $args{style_weekly}  // 'SOLID',
        style_monthly => $args{style_monthly} // 'SOLID',
    };
    bless $self, $class;
    return $self;
}

# render($scale, $levels, $vis, $start_idx, $last_data_idx)
#   La linea va desde x=0 hasta unos pocos candles despues de la ultima barra.
#   La etiqueta aparece al final de la linea.
sub render {
    my ($self, $scale, $levels, $vis, $start_idx, $last_data_idx) = @_;
    my $c = $self->{canvas};

    $c->delete('mtf_levels');

    return unless defined $levels && %$levels;

    my $show_daily   = $vis->{mtf_daily}   // 0;
    my $show_weekly  = $vis->{mtf_weekly}  // 0;
    my $show_monthly = $vis->{mtf_monthly} // 0;

    return unless $show_daily || $show_weekly || $show_monthly;

    my $width  = $c->width;
    my $height = $c->height;
    return if $width <= 1 || $height <= 1;

    $start_idx     //= 0;
    $last_data_idx //= 0;

    # Ancho de una vela en pixeles
    my $visible_bars = $scale->{visible_bars} || 1;
    my $candle_width = $scale->_drawable_width() / $visible_bars;

    # Posicion X del centro del ultimo bar de datos
    my $last_bar_rel = $last_data_idx - $start_idx;
    my $x_last_center = $scale->index_to_center_x($last_bar_rel);

    # La linea termina ~4 barras despues de la ultima vela (como Pine: rEnd + 20*tf)
    # Pero clampeado al area de velas (sin meterse en el margen del eje de precio)
    my $draw_w    = $width - RIGHT_MARGIN;
    my $x_end     = $x_last_center + ($candle_width * 4);
    $x_end        = $draw_w - 4 if $x_end > $draw_w - 4;

    # Si la ultima barra esta completamente fuera de la pantalla a la derecha -> no dibujar
    return if $x_last_center > $draw_w + $candle_width;

    # La linea siempre empieza desde el borde izquierdo visible (x=0)
    my $x_start = 0;

    # Convertir estilo a dash de Tk
    my $dash_for = sub {
        my ($style) = @_;
        return undef    if ($style // 'SOLID') eq 'SOLID';
        return [8, 4]   if $style eq 'DASHED';
        return [2, 4]   if $style eq 'DOTTED';
        return undef;
    };

    my $draw_level = sub {
        my ($price, $label, $color, $style) = @_;
        return unless defined $price && $price > 0;

        my $y = $scale->value_to_y($price);
        return if $y < 0 || $y > $height;

        my $dash = $dash_for->($style);

        # Linea horizontal desde x=0 hasta x_end
        if (defined $dash) {
            $c->createLine($x_start, $y, $x_end, $y,
                -fill  => $color,
                -width => 1,
                -dash  => $dash,
                -tags  => 'mtf_levels');
        } else {
            $c->createLine($x_start, $y, $x_end, $y,
                -fill  => $color,
                -width => 1,
                -tags  => 'mtf_levels');
        }

        # Etiqueta al final de la linea, dentro del grafico
        $c->createText(
            $x_end + 4, $y,
            -text   => $label,
            -fill   => $color,
            -anchor => 'w',
            -font   => ['Helvetica', 8, 'bold'],
            -tags   => 'mtf_levels',
        );
    };

    if ($show_daily) {
        $draw_level->($levels->{daily_high},  'PDH', $self->{color_daily},   $self->{style_daily});
        $draw_level->($levels->{daily_low},   'PDL', $self->{color_daily},   $self->{style_daily});
    }

    if ($show_weekly) {
        $draw_level->($levels->{weekly_high}, 'PWH', $self->{color_weekly},  $self->{style_weekly});
        $draw_level->($levels->{weekly_low},  'PWL', $self->{color_weekly},  $self->{style_weekly});
    }

    if ($show_monthly) {
        $draw_level->($levels->{monthly_high}, 'PMH', $self->{color_monthly}, $self->{style_monthly});
        $draw_level->($levels->{monthly_low},  'PML', $self->{color_monthly}, $self->{style_monthly});
    }
}

1;
