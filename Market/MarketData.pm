package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);

sub new {
    my ($class) = @_;
    my $self = {
        data         => {},
        current_tf   => '1m',
        # Variables nativas para el Sistema Replay
        replay_mode  => 0,
        replay_index => 0,
    };
    bless $self, $class;
    return $self;
}

sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}->{'1m'} }, $candle;
}

sub build_tf_candles {
    my ($self, $target_tf) = @_;

    # Parsear dinámicamente minutos, horas, días o semanas
    my $n;
    if ($target_tf =~ /^(\d+)m$/) {
        $n = $1;
    } elsif ($target_tf =~ /^(\d+)h$/) {
        $n = $1 * 60;
    } elsif ($target_tf eq 'D') {
        $n = 1440;
    } elsif ($target_tf eq 'W') {
        $n = 10080;
    }
    
    return unless $n && $n > 0;
    return unless exists $self->{data}->{'1m'} && @{ $self->{data}->{'1m'} } > 0;

    my $base_data = $self->{data}->{'1m'};
    my @aggregated;
    my %bucket_map;

    for my $candle (@$base_data) {
        my $ts = $candle->{timestamp};

        my ($date, $hour, $min);
        if ($ts =~ /(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2})/) {
            $date = $1;
            $hour = $2 + 0;
            $min  = $3 + 0;
        } else {
            next; 
        }

        my $day_minute = $hour * 60 + $min;
        my $bucket     = floor($day_minute / $n) * $n;
        my $key        = "$date:$bucket";

        if (!exists $bucket_map{$key}) {
            my $bucket_hour = floor($bucket / 60);
            my $bucket_min  = $bucket % 60;
            my $bucket_ts   = sprintf("%sT%02d:%02d:00", $date, $bucket_hour, $bucket_min);
            if ($ts =~ /([-+]\d{2}:\d{2})$/) { $bucket_ts .= $1; }

            push @aggregated, {
                timestamp => $bucket_ts,
                open      => $candle->{open},
                high      => $candle->{high},
                low       => $candle->{low},
                close     => $candle->{close},
                volume    => $candle->{volume},
            };
            $bucket_map{$key} = $#aggregated;
        } else {
            my $idx = $bucket_map{$key};
            $aggregated[$idx]->{high}   = $candle->{high}   if $candle->{high}   > $aggregated[$idx]->{high};
            $aggregated[$idx]->{low}    = $candle->{low}    if $candle->{low}    < $aggregated[$idx]->{low};
            $aggregated[$idx]->{close}  = $candle->{close};
            $aggregated[$idx]->{volume} += $candle->{volume};
        }
    }

    $self->{data}->{$target_tf} = \@aggregated;
}

sub build_timeframes {
    my ($self) = @_;
    # Generar todas las temporalidades soportadas exigidas
    foreach my $tf (qw(5m 15m 1h 2h 4h D W)) {
        $self->build_tf_candles($tf);
    }
    $self->set_timeframe('1m');
}

sub set_timeframe {
    my ($self, $tf) = @_;
    if (exists $self->{data}->{$tf}) {
        $self->{current_tf} = $tf;
    } else {
        warn "La temporalidad $tf no ha sido construida aún.\n";
    }
}

# =====================================================================
# RUTINAS DE ACCESO BLINDADAS CONTRA UNDEF
# =====================================================================
sub _active_array {
    my ($self) = @_;
    # BLINDAJE MAESTRO: Si la temporalidad actual no tiene datos o es undef, 
    # devolvemos un arreglo vacío [] en lugar de undef.
    return $self->{data}->{ $self->{current_tf} } // [];
}

# =====================================================================
# SISTEMA REPLAY: Filtrado Estricto de Datos
# =====================================================================
sub start_replay {
    my ($self, $index) = @_;
    $self->{replay_mode} = 1;
    $self->{replay_index} = $index // 0;
}

sub stop_replay {
    my ($self) = @_;
    $self->{replay_mode} = 0;
}

sub step_replay {
    my ($self, $steps) = @_;
    return unless $self->{replay_mode};
    my $array_ref = $self->_active_array();
    
    $self->{replay_index} += $steps;
    # Protegemos el avance comprobando primero que el arreglo tenga elementos
    $self->{replay_index} = $#{$array_ref} if @$array_ref && $self->{replay_index} > $#{$array_ref};
    $self->{replay_index} = 0 if $self->{replay_index} < 0;
}

sub size {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    # Si el arreglo está vacío, el tamaño es 0 directo
    return 0 unless @$array_ref; 
    return $self->{replay_mode} ? $self->{replay_index} + 1 : scalar @{$array_ref};
}

sub get_slice {
    my ($self, $start, $end) = @_;
    my $array_ref = $self->_active_array();
    return [] unless @$array_ref;
    
    my $max_limit = $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
    
    $start = 0 if $start < 0;
    $end = $max_limit if $end > $max_limit;
    
    return [] if $start > $end;
    return [ @{$array_ref}[$start .. $end] ];
}

sub last_candle {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    my $idx = $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
    return $array_ref->[$idx] if $idx >= 0;
    return undef;
}

sub get_timestamp {
    my ($self, $index) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return $array_ref->[$index]->{timestamp} if defined $array_ref->[$index];
    return undef;
}

sub last_index {
    my ($self) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return $self->{replay_mode} ? $self->{replay_index} : $#{$array_ref};
}

sub get_candle {
    my ($self, $index) = @_;
    my $array_ref = $self->_active_array();
    return undef unless @$array_ref;
    
    return undef if !defined $index || $index < 0 || $index > $#{$array_ref};
    return undef if $self->{replay_mode} && $index > $self->{replay_index};
    
    return $array_ref->[$index];
}
# MTF LEVELS: PDH/PDL, PWH/PWL, PMH/PML
#
# Calcula directamente desde los datos 1m, agrupando por:
#   - Día calendario       → Daily H/L
#   - Semana ISO (lunes)   → Weekly H/L
#   - Año-Mes              → Monthly H/L
#
# Devuelve el H/L de la vela ANTERIOR completamente cerrada en cada TF.
# (Equivalente a request.security(..., high[1], low[1], lookahead=on) en Pine)
# =====================================================================
sub get_mtf_levels {
    my ($self) = @_;

    my %levels;

    # Solo usamos los datos 1m (fuente de verdad)
    return \%levels unless exists $self->{data}{'1m'} && @{ $self->{data}{'1m'} };

    # Obtener el timestamp de la última vela disponible (respeta replay)
    my $last = $self->last_candle();
    return \%levels unless defined $last;
    my $last_ts = $last->{timestamp};

    # Extraer fecha actual y sus componentes
    my ($cur_date, $cur_ym) = ('', '');
    if ($last_ts =~ /^(\d{4}-(\d{2})-(\d{2}))/) {
        $cur_date = $1;
        $cur_ym   = "$1";
        $cur_ym   =~ s/-\d{2}$//;    # "2026-07"
    }

    # ── Acumuladores por periodo ─────────────────────────────────────────────
    my %by_day;    # "YYYY-MM-DD"     => { high, low }
    my %by_week;   # "YYYY-WW"        => { high, low }  (ISO week, Monday-anchored)
    my %by_month;  # "YYYY-MM"        => { high, low }

    # Limite de datos: solo candles ANTES del día actual
    my $limit_ts = "${cur_date}T00:00:00";
    my $arr = $self->{data}{'1m'};

    # En modo replay, solo considerar hasta replay_index
    my $max_i = $self->{replay_mode} ? $self->{replay_index} : $#{$arr};

    for my $i (0 .. $max_i) {
        my $c  = $arr->[$i];
        my $ts = $c->{timestamp} // '';

        # Solo candles completamente anteriores al día actual
        next unless $ts lt $limit_ts;

        my ($date, $year, $mon, $day, $h, $m) = ('','','','','','');
        next unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})/;
        ($year, $mon, $day, $h, $m) = ($1, $2, $3, $4, $5);
        $date = "$year-$mon-$day";

        # Clave de mes
        my $ym = "$year-$mon";

        # Clave de semana ISO (lunes = inicio de semana)
        # Usamos el algoritmo Zeller simplificado para obtener el día de semana
        # y retroceder al lunes
        my $dow = _day_of_week($year, $mon, $day);  # 0=Mon..6=Sun
        my $days_since_mon = $dow;
        my ($wy, $wm, $wd) = _date_add($year, $mon, $day, -$days_since_mon);
        my $week_key = sprintf("%04d-%02d-%02d", $wy, $wm, $wd);

        # Actualizar acumuladores
        for my $bucket_key ($date) {
            if (!exists $by_day{$date}) {
                $by_day{$date} = { high => $c->{high}, low => $c->{low} };
            } else {
                $by_day{$date}{high} = $c->{high} if $c->{high} > $by_day{$date}{high};
                $by_day{$date}{low}  = $c->{low}  if $c->{low}  < $by_day{$date}{low};
            }
        }

        if (!exists $by_week{$week_key}) {
            $by_week{$week_key} = { high => $c->{high}, low => $c->{low} };
        } else {
            $by_week{$week_key}{high} = $c->{high} if $c->{high} > $by_week{$week_key}{high};
            $by_week{$week_key}{low}  = $c->{low}  if $c->{low}  < $by_week{$week_key}{low};
        }

        if (!exists $by_month{$ym}) {
            $by_month{$ym} = { high => $c->{high}, low => $c->{low} };
        } else {
            $by_month{$ym}{high} = $c->{high} if $c->{high} > $by_month{$ym}{high};
            $by_month{$ym}{low}  = $c->{low}  if $c->{low}  < $by_month{$ym}{low};
        }
    }

    # ── Tomar el periodo ANTERIOR al actual en cada TF ───────────────────────

    # Daily: último día antes de hoy
    if (%by_day) {
        my @days = sort keys %by_day;
        my $prev_day = $days[-1];   # último día con datos anteriores al de hoy
        if (defined $prev_day) {
            $levels{daily_high} = $by_day{$prev_day}{high};
            $levels{daily_low}  = $by_day{$prev_day}{low};
        }
    }

    # Weekly: última semana (por clave YYYY-MM-DD del lunes) anterior a esta semana
    if (%by_week) {
        # La semana actual: lunes de la semana del último timestamp
        my ($ly, $lm, $ld) = ('', '', '');
        if ($last_ts =~ /^(\d{4})-(\d{2})-(\d{2})/) {
            ($ly, $lm, $ld) = ($1, $2, $3);
        }
        my $dow_now = _day_of_week($ly, $lm, $ld);
        my ($cwy, $cwm, $cwd) = _date_add($ly, $lm, $ld, -$dow_now);
        my $cur_week_key = sprintf("%04d-%02d-%02d", $cwy, $cwm, $cwd);

        my @weeks = sort keys %by_week;
        my $prev_week;
        for my $wk (@weeks) {
            last if $wk ge $cur_week_key;
            $prev_week = $wk;
        }
        if (defined $prev_week) {
            $levels{weekly_high} = $by_week{$prev_week}{high};
            $levels{weekly_low}  = $by_week{$prev_week}{low};
        }
    }

    # Monthly: último mes anterior al mes actual
    if (%by_month) {
        my @months = sort keys %by_month;
        my $prev_month;
        for my $mo (@months) {
            last if $mo ge $cur_ym;
            $prev_month = $mo;
        }
        if (defined $prev_month) {
            $levels{monthly_high} = $by_month{$prev_month}{high};
            $levels{monthly_low}  = $by_month{$prev_month}{low};
        }
    }

    return \%levels;
}

# ── Helpers de calendario ────────────────────────────────────────────────────

# _day_of_week($y, $m, $d) → 0=Lunes, 1=Martes, ... 6=Domingo
# Algoritmo de Tomohiko Sakamoto (portable, sin módulos externos)
sub _day_of_week {
    my ($y, $m, $d) = @_;
    my @t = (0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4);
    $y-- if $m < 3;
    my $dow = ($y + int($y/4) - int($y/100) + int($y/400) + $t[$m-1] + $d) % 7;
    # 0=Sun → convertir a 0=Mon
    return ($dow + 6) % 7;
}

# _date_add($y, $m, $d, $delta_days) → ($ny, $nm, $nd)
# Suma delta_days a una fecha. Solo funciona para deltas pequeños (<30).
sub _date_add {
    my ($y, $m, $d, $delta) = @_;
    $d += $delta;
    my @days_in = (0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    $days_in[2] = 29 if ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0));
    while ($d < 1) {
        $m--;
        if ($m < 1) { $m = 12; $y--; }
        $days_in[2] = 29 if ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0));
        $d += $days_in[$m];
    }
    while ($d > $days_in[$m]) {
        $d -= $days_in[$m];
        $m++;
        if ($m > 12) { $m = 1; $y++; }
        $days_in[2] = 29 if ($y % 4 == 0 && ($y % 100 != 0 || $y % 400 == 0));
    }
    return ($y, $m, $d);
}

1;