# =============================================================================
# Market::Overlays::MTF_Levels
#
# Puerto visual del bloque "MTF LEVELS" del Pine Script:
#   "Smart Money Concepts Pro [Neon]"
#
# Dibuja líneas horizontales (PDH, PDL, PWH, PWL, PMH, PML) que representan
# el High y Low de la vela completamente cerrada en cada temporalidad superior.
# =============================================================================
package Market::Overlays::MTF_Levels;

use strict;
use warnings;

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas => $args{canvas},
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

sub render {
    my ($self, $scale, $levels, $vis) = @_;
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

        if (defined $dash) {
            $c->createLine(0, $y, $width, $y,
                -fill  => $color,
                -width => 1,
                -dash  => $dash,
                -tags  => 'mtf_levels');
        } else {
            $c->createLine(0, $y, $width, $y,
                -fill  => $color,
                -width => 1,
                -tags  => 'mtf_levels');
        }

        $c->createText(
            $width - 4, $y - 8,
            -text   => $label,
            -fill   => $color,
            -anchor => 'ne',
            -font   => ['Helvetica', 8, 'bold'],
            -tags   => 'mtf_levels',
        );
    };

    if ($show_daily) {
        my $col   = $self->{color_daily};
        my $style = $self->{style_daily};
        $draw_level->($levels->{daily_high},  'PDH', $col, $style);
        $draw_level->($levels->{daily_low},   'PDL', $col, $style);
    }

    if ($show_weekly) {
        my $col   = $self->{color_weekly};
        my $style = $self->{style_weekly};
        $draw_level->($levels->{weekly_high}, 'PWH', $col, $style);
        $draw_level->($levels->{weekly_low},  'PWL', $col, $style);
    }

    if ($show_monthly) {
        my $col   = $self->{color_monthly};
        my $style = $self->{style_monthly};
        $draw_level->($levels->{monthly_high}, 'PMH', $col, $style);
        $draw_level->($levels->{monthly_low},  'PML', $col, $style);
    }
}

1;
