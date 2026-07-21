sub clip_line {
    my ($x0, $y0, $x1, $y1, $min_x, $min_y, $max_x, $max_y) = @_;
    
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
}

my @res = clip_line(-5000, 100, 5000, 500, -2000, -2000, 3000, 3000);
print "Result: @res\n";
