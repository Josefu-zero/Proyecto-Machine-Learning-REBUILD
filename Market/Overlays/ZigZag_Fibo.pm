package Market::Overlays::ZigZag_Fibo;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
        color_up   => $args{color_up}   // '#00ff00',
        color_dn   => $args{color_dn}   // '#ff0000',
        color_fibo => $args{color_fibo} // '#00ff00',
        color_txt  => $args{color_txt}  // '#0000ff',
        line_width => $args{line_width} // 2,
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $indicator, $start_idx, $visibility) = @_;
    my $c = $self->{canvas};
    
    $c->delete('zz_fibo');
    
    $visibility //= {};
    my $show_zz   = $visibility->{fibo_zigzag} // 1;
    my $show_fibo = $visibility->{fibo_levels} // 1;
    
    return unless $show_zz || $show_fibo;
    
    my $zz = $indicator->get_zigzag();
    return if scalar @$zz < 6; # Necesitamos al menos 3 puntos (6 elementos)
    
    my $width  = $c->width;
    my $height = $c->height;
    return if $width <= 0 || $height <= 0;
    
    my $y_of = sub {
        my ($val) = @_;
        return $scale->value_to_y($val);
    };
    
    my $x_of = sub {
        my ($bindex) = @_;
        my $rel = $bindex - $start_idx;
        return $scale->index_to_center_x($rel);
    };

    my $dir = $indicator->get_dir();
    
    # 1. Dibujar ZigZag
    if ($show_zz) {
        for (my $i = 0; $i < scalar(@$zz) - 3; $i += 2) {
            my $v1 = $zz->[$i];
            my $x1 = $x_of->($zz->[$i+1]);
            my $y1 = $y_of->($v1);
            
            my $v2 = $zz->[$i+2];
            my $x2 = $x_of->($zz->[$i+3]);
            my $y2 = $y_of->($v2);
            
            # El segmento más reciente (i=0) podría ser punteado para indicar que está en desarrollo
            my $dash = ($i == 0) ? [4, 4] : undef;
            my $color = ($dir == 1) ? $self->{color_up} : $self->{color_dn};
            # Invertimos color en segmentos alternos
            if (($i/2) % 2 != 0) {
                $color = ($dir == 1) ? $self->{color_dn} : $self->{color_up};
            }
            
            # Simple clip check
            next if ($x1 < 0 && $x2 < 0) || ($x1 > $width && $x2 > $width);
            
            $c->createLine(
                $x2, $y2, $x1, $y1,
                -fill => $color,
                -width => $self->{line_width},
                -dash => $dash,
                -tags => ['zz_fibo']
            );
        }
    }
    
    # 2. Dibujar Niveles Fibonacci
    if ($show_fibo && scalar(@$zz) >= 6) {
        # Fibonacci base = zigzag[2], height = zigzag[4]
        # Pine: diff = zigzag[4] - zigzag[2]
        my $v_2 = $zz->[2]; # Prev pivot
        my $v_4 = $zz->[4]; # Pivot before prev
        my $x_5 = $x_of->($zz->[5]); # X of pivot before prev
        
        my $diff = $v_4 - $v_2;
        my $ratios = $indicator->get_fibo_ratios();
        
        my $levels_to_show = 6; # Mostrar los primeros 6 (0 hasta 0.786)
        
        for my $i (0 .. $#$ratios) {
            last if $i > $levels_to_show;
            my $ratio = $ratios->[$i];
            my $fibo_val = $v_2 + $diff * $ratio;
            my $y_fibo = $y_of->($fibo_val);
            
            if ($y_fibo >= 0 && $y_fibo <= $height) {
                # Línea horizontal hasta el final derecho
                $c->createLine(
                    $x_5, $y_fibo, $width, $y_fibo,
                    -fill => $self->{color_fibo},
                    -dash => [2, 2],
                    -tags => ['zz_fibo']
                );
                
                # Etiqueta de precio
                my $txt = sprintf("%.3f (%.2f)", $ratio, $fibo_val);
                $c->createText(
                    $width - 5, $y_fibo - 10,
                    -text => $txt,
                    -fill => $self->{color_txt},
                    -anchor => 'e',
                    -tags => ['zz_fibo']
                );
            }
            
            # Condición de stop de Pine script
            if (($dir == 1 && $fibo_val > $zz->[0]) || ($dir == -1 && $fibo_val < $zz->[0])) {
                # Stop drawing higher levels if current price breached it? 
                # En Pine, stopit = true. Aquí lo ignoraremos o aplicaremos si es necesario.
            }
        }
    }
}

1;
