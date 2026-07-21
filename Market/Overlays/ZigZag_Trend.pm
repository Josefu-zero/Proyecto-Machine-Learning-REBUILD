# This Perl code is a port of logic from:
#   "ZigZag Volume Profile [ChartPrime]" (Pine Script® v6)
#   Subject to the terms of the Mozilla Public License 2.0
#   https://mozilla.org/MPL/2.0/
#   © ChartPrime
#
# Port author: Proyecto-Machine-Learning
# Overlay de renderizado para Market::Indicators::ZigZag_Trend

package Market::Overlays::ZigZag_Trend;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas         => $args{canvas},
        color_bullish  => $args{color_bullish} || '#26a69a',  # verde teal
        color_bearish  => $args{color_bearish}  || '#ef5350',  # rojo
        line_width     => $args{line_width}     || 2,
    };
    bless $self, $class;
    return $self;
}

sub render {
    my ($self, $scale, $zz_slice, $start_idx_viewport, $visibility) = @_;
    my $c = $self->{canvas};

    $c->delete('zigzag_overlay');

    $visibility //= {};
    return unless ($visibility->{zigzag} // 1);
    return unless $zz_slice && @$zz_slice;
    $start_idx_viewport //= 0;

    my $width        = $c->width;
    my $height       = $c->height;
    my $min_val      = $scale->{min_val};
    my $max_val      = $scale->{max_val};
    my $visible_bars = $scale->{visible_bars};
    my $offset_frac  = $scale->{offset};

    my $range = $max_val - $min_val;
    return if $range <= 0;

    my $candle_width = $scale->_drawable_width() / $visible_bars;

    # -------------------------------------------------------------------------
    # 1. Recopilar todos los segmentos visibles a partir de la última barra
    #    que tenga datos de segmentos.
    #    Tomamos el snapshot de la última barra visible: contiene todos los
    #    tramos completados + el tramo activo (repaint).
    # -------------------------------------------------------------------------
    my $last_data = undef;
    for my $i (reverse 0 .. $#$zz_slice) {
        if (defined $zz_slice->[$i]) {
            $last_data = $zz_slice->[$i];
            last;
        }
    }
    return unless defined $last_data;

    # Tramos completados + tramo activo (si existe)
    my @all_segments = @{ $last_data->{segments} // [] };
    push @all_segments, $last_data->{active_segment}
        if defined $last_data->{active_segment};

    # -------------------------------------------------------------------------
    # 2. Dibujar cada segmento del ZigZag como una línea
    # Cohen-Sutherland line clipping para evitar desbordamientos de Tk al hacer zoom
    my $clip_line = sub {
        my ($x0, $y0, $x1, $y1) = @_;
        my ($min_x, $min_y, $max_x, $max_y) = (-25000, -25000, 25000, 25000);
        my $compute_outcode = sub {
            my ($x, $y) = @_;
            my $code = 0;
            $code |= 1 if $x < $min_x; $code |= 2 if $x > $max_x;
            $code |= 4 if $y < $min_y; $code |= 8 if $y > $max_y;
            return $code;
        };
        my $outcode0 = $compute_outcode->($x0, $y0);
        my $outcode1 = $compute_outcode->($x1, $y1);
        my $accept = 0;
        while (1) {
            if (!($outcode0 | $outcode1)) { $accept = 1; last; }
            elsif ($outcode0 & $outcode1) { last; }
            else {
                my $x; my $y;
                my $outcode_out = $outcode0 ? $outcode0 : $outcode1;
                if ($outcode_out & 8) { $x = $x0 + ($x1 - $x0) * ($max_y - $y0) / ($y1 - $y0); $y = $max_y; }
                elsif ($outcode_out & 4) { $x = $x0 + ($x1 - $x0) * ($min_y - $y0) / ($y1 - $y0); $y = $min_y; }
                elsif ($outcode_out & 2) { $y = $y0 + ($y1 - $y0) * ($max_x - $x0) / ($x1 - $x0); $x = $max_x; }
                elsif ($outcode_out & 1) { $y = $y0 + ($y1 - $y0) * ($min_x - $x0) / ($x1 - $x0); $x = $min_x; }
                if ($outcode_out == $outcode0) { $x0 = $x; $y0 = $y; $outcode0 = $compute_outcode->($x0, $y0); }
                else { $x1 = $x; $y1 = $y; $outcode1 = $compute_outcode->($x1, $y1); }
            }
        }
        return $accept ? ($x0, $y0, $x1, $y1) : ();
    };

    # -------------------------------------------------------------------------
    # 2. Dibujar las líneas del zigzag (tramos confirmados)
    # -------------------------------------------------------------------------
    for my $seg (@all_segments) {
        next unless defined $seg->{from_bar} && defined $seg->{to_bar};
        next unless defined $seg->{from_price} && defined $seg->{to_price};

        # Convertir índices absolutos a relativos a la ventana visible
        my $rel_from = $seg->{from_bar} - $start_idx_viewport;
        my $rel_to   = $seg->{to_bar}   - $start_idx_viewport;

        my $x1 = $scale->index_to_center_x($rel_from);
        my $x2 = $scale->index_to_center_x($rel_to);

        my $y1 = $scale->value_to_y($seg->{from_price});
        my $y2 = $scale->value_to_y($seg->{to_price});

        # Saltar segmentos completamente fuera de la pantalla
        next if ($x1 < 0 && $x2 < 0) || ($x1 > $width && $x2 > $width);

        my $color = ($seg->{direction} // '') eq 'bullish'
            ? $self->{color_bullish}
            : $self->{color_bearish};

        if (my @coords = $clip_line->($x1, $y1, $x2, $y2)) {
            $c->createLine(
                @coords,
                -fill  => $color,
                -width => $self->{line_width},
                -tags  => ['zigzag_overlay'],
            );
        }
    }

    # -------------------------------------------------------------------------
    # 3. Dibujar marcadores en los pivotes confirmados de la última barra visible
    #    (pequeños círculos en los extremos)
    # -------------------------------------------------------------------------
    my $last_bar_data = $zz_slice->[-1];
    if (defined $last_bar_data) {

        # Pivote alto
        if (defined $last_bar_data->{pivot_high}) {
            my $ph = $last_bar_data->{pivot_high};
            my $rel = $ph->{bar_index} - $start_idx_viewport;
            my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
            my $py  = $height - ((($ph->{price} - $min_val) / $range) * $height);
            my $r   = 4;
            if ($px >= -$r && $px <= $width + $r) {
                $c->createOval(
                    $px - $r, $py - $r, $px + $r, $py + $r,
                    -fill    => $self->{color_bearish},
                    -outline => $self->{color_bearish},
                    -tags    => ['zigzag_overlay'],
                );
            }
        }

        # Pivote bajo
        if (defined $last_bar_data->{pivot_low}) {
            my $pl = $last_bar_data->{pivot_low};
            my $rel = $pl->{bar_index} - $start_idx_viewport;
            my $px  = ($rel - $offset_frac) * $candle_width + ($candle_width / 2);
            my $py  = $height - ((($pl->{price} - $min_val) / $range) * $height);
            my $r   = 4;
            if ($px >= -$r && $px <= $width + $r) {
                $c->createOval(
                    $px - $r, $py - $r, $px + $r, $py + $r,
                    -fill    => $self->{color_bullish},
                    -outline => $self->{color_bullish},
                    -tags    => ['zigzag_overlay'],
                );
            }
        }
    }

    # Empujar el overlay de zigzag debajo de las velas para no taparlas
    $c->lower('zigzag_overlay');
}

1;
