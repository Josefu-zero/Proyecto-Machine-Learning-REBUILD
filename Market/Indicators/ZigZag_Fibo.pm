package Market::Indicators::ZigZag_Fibo;

use strict;
use warnings;
use List::Util qw(max min);

# Constructor
sub new {
    my ($class, %args) = @_;
    my $self = {
        tf  => $args{tf}  // '1h', # Resolución (1m, 5m, 15m, 1h, 2h, 4h, D, W)
        prd => $args{prd} // 2,    # Periodo (por defecto 2)
    };
    bless $self, $class;
    $self->reset();
    return $self;
}

sub reset {
    my ($self) = @_;
    $self->{_highs}             = [];
    $self->{_lows}              = [];
    $self->{_day_starts}        = [];
    $self->{_current_day}       = undef;
    $self->{_dir}               = 0;
    
    # Zigzag arrays (index 0 is newest, like Pine push/unshift)
    $self->{_zigzag}            = [];
    $self->{_oldzigzag}         = [];
    
    # Para Fibonacci Ratios
    $self->{fibo_ratios} = [
        0.000, 0.236, 0.382, 0.500, 0.618, 0.786,
        1, 1.272, 1.414, 1.618,
        2, 2.272, 2.414, 2.618,
        3, 3.272, 3.414, 3.618,
        4, 4.272, 4.414, 4.618,
        5, 5.272, 5.414, 5.618
    ];
}

sub update_last {
    my ($self, $market_data) = @_;
    my $last_idx = $market_data->size() - 1;
    return if $last_idx < 0;
    
    my $candle = $market_data->get_candle($last_idx);
    $self->_process_bar($last_idx, $candle, $market_data);
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

# Devuelve los pivotes actuales del zigzag (para dibujar líneas)
sub get_zigzag {
    my ($self) = @_;
    return [ @{ $self->{_zigzag} } ];
}
sub get_oldzigzag {
    my ($self) = @_;
    return [ @{ $self->{_oldzigzag} } ];
}
sub get_dir {
    my ($self) = @_;
    return $self->{_dir};
}

# Devuelve los ratios fijos
sub get_fibo_ratios {
    my ($self) = @_;
    return $self->{fibo_ratios};
}

# Agrega un punto al array _zigzag
sub _add_to_zigzag {
    my ($self, $value, $bindex) = @_;
    my $zz = $self->{_zigzag};
    
    # Copiamos a oldzigzag antes de cambiar
    $self->{_oldzigzag} = [ @$zz ];
    
    unshift @$zz, $bindex;
    unshift @$zz, $value;
    
    if (scalar @$zz > 50) {
        pop @$zz;
        pop @$zz;
    }
}

# Actualiza el último punto
sub _update_zigzag {
    my ($self, $value, $bindex) = @_;
    my $zz = $self->{_zigzag};
    
    if (scalar @$zz == 0) {
        $self->_add_to_zigzag($value, $bindex);
    } else {
        my $dir = $self->{_dir};
        if (($dir == 1 && $value > $zz->[0]) || ($dir == -1 && $value < $zz->[0])) {
            # Se crea una copia nueva antes de modificar si queremos mantener el rastro, 
            # pero Pine en update no copia a oldzigzag.
            $zz->[0] = $value;
            $zz->[1] = $bindex;
        }
    }
}

sub _get_tf_key {
    my ($self, $ts) = @_;
    my $tf = $self->{tf};
    if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/) {
        my ($y, $m, $d, $H, $M) = ($1, $2, $3, $4, $5);
        if ($tf eq '1m')  { return "$y-$m-$d $H:$M"; }
        if ($tf eq '5m')  { return sprintf("%s-%s-%s %02d:%02d", $y, $m, $d, $H, int($M/5)*5); }
        if ($tf eq '15m') { return sprintf("%s-%s-%s %02d:%02d", $y, $m, $d, $H, int($M/15)*15); }
        if ($tf eq '1h')  { return "$y-$m-$d $H"; }
        if ($tf eq '2h')  { return sprintf("%s-%s-%s %02d", $y, $m, $d, int($H/2)*2); }
        if ($tf eq '4h')  { return sprintf("%s-%s-%s %02d", $y, $m, $d, int($H/4)*4); }
        if ($tf eq 'D')   { return "$y-$m-$d"; }
        if ($tf eq 'W')   {
            use Time::Local;
            # Aproximación simple usando timelocal
            my $time = eval { timegm(0, $M, $H, $d, $m - 1, $y) };
            if ($@ || !$time) { return "$y-W"; }
            my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = gmtime($time);
            my $days_since_monday = ($wday == 0) ? 6 : $wday - 1;
            my $monday = $time - ($days_since_monday * 86400);
            my ($lmday, $lmon, $lyear) = (gmtime($monday))[3,4,5];
            return sprintf("%04d-%02d-%02d", $lyear+1900, $lmon+1, $lmday);
        }
    }
    return $ts;
}

sub _process_bar {
    my ($self, $bar_idx, $candle, $market_data) = @_;
    
    my $h = $candle->{high};
    my $l = $candle->{low};
    my $ts = $candle->{timestamp};
    
    # Track highs and lows
    push @{ $self->{_highs} }, $h;
    push @{ $self->{_lows}  }, $l;
    
    # Detectar cambio de bloque de tiempo (MTF logic)
    my $tf_key = $self->_get_tf_key($ts);
    if (!defined $self->{_current_day} || $self->{_current_day} ne $tf_key) {
        $self->{_current_day} = $tf_key;
        push @{ $self->{_day_starts} }, $bar_idx;
        # Mantener solo prd periodos
        if (scalar @{ $self->{_day_starts} } > $self->{prd}) {
            shift @{ $self->{_day_starts} };
        }
    }
    
    # Calcular 'len' dinámico
    my $bi = $self->{_day_starts}[0] // 0;
    my $len = $bar_idx - $bi + 1;
    $len = 1 if $len < 1;
    
    # Trim highs and lows arrays to max possible len needed? No, solo leer los últimos $len
    # Pero para no consumir memoria infinita:
    if (scalar @{ $self->{_highs} } > $len + 10) {
        shift @{ $self->{_highs} };
        shift @{ $self->{_lows} };
    }
    
    # Extraer los últimos $len elementos
    my $start_idx = scalar @{ $self->{_highs} } - $len;
    $start_idx = 0 if $start_idx < 0;
    
    my @recent_highs = @{ $self->{_highs} }[$start_idx .. $#{ $self->{_highs} }];
    my @recent_lows  = @{ $self->{_lows}  }[$start_idx .. $#{ $self->{_lows}  }];
    
    my $highest = max(@recent_highs);
    my $lowest  = min(@recent_lows);
    
    my $ph = ($h == $highest) ? $h : undef;
    my $pl = ($l == $lowest)  ? $l : undef;
    
    my $dir_prev = $self->{_dir};
    
    if (defined $ph && !defined $pl) {
        $self->{_dir} = 1;
    } elsif (defined $pl && !defined $ph) {
        $self->{_dir} = -1;
    }
    
    my $dir_changed = ($self->{_dir} != $dir_prev);
    
    if (defined $ph || defined $pl) {
        my $val = ($self->{_dir} == 1) ? $ph : $pl;
        
        $val = $ph if !defined $val && defined $ph;
        $val = $pl if !defined $val && defined $pl;

        if ($dir_changed) {
            $self->_add_to_zigzag($val, $bar_idx);
        } else {
            $self->_update_zigzag($val, $bar_idx);
        }
    }
}

1;
