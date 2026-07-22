package Market::ChartEngine;

use strict;
use warnings;
use utf8;
use lib '/home/davidandresvm/Documentos/ProyectoMLv2';

use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

use Market::Overlays::Liquidity;
use Market::Overlays::SMC_Structures;
use Market::Overlays::ZigZag_Trend;
use Market::Overlays::Volume_Profile;
use Market::Overlays::Anchored_VWAP;
use Market::Overlays::ZigZag_VolumeProfile;
use Market::Overlays::ZigZag_Fibo;
use Market::Overlays::MTF_Levels;
sub new {
    my ($class, %args) = @_;
    
    # Empezamos asumiendo 100 velas y un margen del 15%
    my $total_candles = $args{market_data}->size();
    my $visible_bars = 100;
    my $margin = $visible_bars * 0.15;
    
    my $self = {
        mw           => $args{mw},
        market_data  => $args{market_data},
        indicators   => $args{indicators},
        price_canvas => $args{price_canvas},
        atr_canvas   => $args{atr_canvas},
        
        # INICIO AL FINAL DE LA DATA + MARGEN
        offset       => $total_candles - $visible_bars + $margin, 
        visible_bars => $visible_bars,
        render_flag  => 0,
        
        drag_start_x      => 0,
        drag_start_offset => 0,

        auto_scale_y   => 1,
        manual_min_y   => 0,
        manual_max_y   => 0,
        drag_start_y   => 0,

        # Escala vertical independiente para el panel ATR
        auto_scale_atr  => 1,
        manual_min_atr  => 0,
        manual_max_atr  => 0,
        drag_start_atr  => 0,
        show_smc        => 1,

        # Hash de visibilidad granular de overlays
        # Cada clave controla una capa de dibujo independiente.
        # 0 = oculto al arrancar (el usuario activa lo que necesite desde la sidebar)
        visibility => {
            zigzag           => 0,  # ZigZag (LonesomeTheBlue)
            # --- SMC Pro [Neon] — Estructura Macro (Swing) ---
            bos_choch        => 1,  # BOS / CHoCH swing (lineas solidas)
            structure_labels => 1,  # Etiquetas HH / HL / LH / LL macro
            strong_weak_hl   => 1,  # Strong / Weak High & Low (trailing)
            # --- SMC Pro [Neon] — Estructura Interna ---
            int_bos_choch        => 0,  # BOS / CHoCH internos (dashed)
            int_structure_labels => 0,  # Etiquetas HH/HL/LH/LL internos
            # --- SMC Pro [Neon] — Order Blocks ---
            order_blocks     => 1,  # Order Blocks de swing
            int_order_blocks => 0,  # Order Blocks internos
            # --- SMC Pro [Neon] — Zonas ---
            fvg              => 1,  # Fair Value Gaps
            eq_highs_lows    => 1,  # Equal Highs / Equal Lows
            premium_discount => 0,  # Zonas Premium / Equilibrium / Discount
            # --- Liquidez ---
            bsl              => 0,  # Buy-Side Liquidity
            ssl              => 0,  # Sell-Side Liquidity
            eqh_eql          => 0,  # Equal Highs / Equal Lows (Liquidity)
            liq_events       => 0,  # Sweeps, Grabs, Runs
            # --- ZigZag Fibo ---
            fibo_zigzag      => 0,
            fibo_levels      => 0,
            # --- Fase 2: Volumen y VWAP ---
            volume_profile   => 0,  # Perfil de Volumen (POC / VAH / VAL)
            vp_histogram     => 0,  # Histograma horizontal del VP
            vp_poc           => 0,  # Linea POC
            vp_va            => 0,  # Lineas VAH / VAL
            anchored_vwap    => 0,  # VWAP Multi-Pivot Anclado
            vwap_markers     => 0,  # Marcadores de ancla del VWAP
            vwap_labels      => 0,  # Etiquetas de valor VWAP
            # --- ZigZag Volume Profile [ChartPrime] ---
            zvp_zigzag       => 0,  # Lineas ZigZag del perfil
            zvp_channel      => 0,  # Canal de swing (ATR)
            zvp_histogram    => 0,  # Histograma de volumen por tramo
            zvp_poc          => 0,  # Linea POC por tramo
            # --- MTF Levels (PDH/PDL, PWH/PWL, PMH/PML) ---
            mtf_daily        => 1,  # Previous Day H/L
            mtf_weekly       => 1,  # Previous Week H/L
            mtf_monthly      => 1,  # Previous Month H/L
        },
        _sidebar_buttons => {},     # refs a widgets de botón para actualizar su estado
    };
    bless $self, $class;

    # Ajustar a los límites si por algún motivo hay muy poca data
    $self->_clamp_offset();

    $self->{price_panel} = Market::Panels::PricePanel->new(canvas => $self->{price_canvas});
    $self->{atr_panel}   = Market::Panels::ATRPanel->new(canvas => $self->{atr_canvas});

    $self->{liquidity_overlay} = Market::Overlays::Liquidity->new(canvas => $self->{price_canvas});
    $self->{smc_overlay}       = Market::Overlays::SMC_Structures->new(canvas => $self->{price_canvas});
    $self->{zigzag_overlay}    = Market::Overlays::ZigZag_Trend->new(canvas => $self->{price_canvas});
    $self->{vp_overlay}        = Market::Overlays::Volume_Profile->new(canvas => $self->{price_canvas});
    $self->{vwap_overlay}      = Market::Overlays::Anchored_VWAP->new(canvas => $self->{price_canvas});
    $self->{zvp_overlay}       = Market::Overlays::ZigZag_VolumeProfile->new(canvas => $self->{price_canvas});
    $self->{zz_fibo_overlay}   = Market::Overlays::ZigZag_Fibo->new(canvas => $self->{price_canvas});
    $self->{mtf_overlay}       = Market::Overlays::MTF_Levels->new(canvas => $self->{price_canvas});
    
    $self->bind_events();
    $self->_build_sidebar($args{sidebar}) if defined $args{sidebar};
    return $self;
}

sub compute_window {
    my ($self) = @_;
    
    my $total_candles = $self->{market_data}->size();
    my $start = int($self->{offset});
    
    # Protecciones estrictas para no pedir índices inexistentes en el arreglo
    $start = 0 if $start < 0;
    $start = $total_candles - 1 if $start >= $total_candles;
    
    my $end = $start + $self->{visible_bars} + 1;
    $end = $total_candles - 1 if $end >= $total_candles;
    
    return ($start, $end);
}

sub request_render {
    my ($self) = @_;
    # Solicita un render diferido 
    # Optimización clave para rendimiento en Tk [cite: 500]
    return if $self->{render_flag};
    $self->{render_flag} = 1;

    # Encola la ejecución del renderizado cuando la aplicación esté inactiva (Idle)
    $self->{mw}->afterIdle(sub { $self->render() });
}

sub render {
    my ($self) = @_;
    $self->{render_flag} = 0;

    my ($start, $end) = $self->compute_window();
    my $data_slice = $self->{market_data}->get_slice($start, $end);
    my $atr_slice  = $self->{indicators}->slice_array('ATR', $start, $end);

    my $width  = $self->{price_canvas}->width;
    my $height = $self->{price_canvas}->height;
    
    my ($min_y, $max_y);
    if ($self->{auto_scale_y}) {
        ($min_y, $max_y) = $self->{price_panel}->get_y_range($data_slice);
    } else {
        $min_y = $self->{manual_min_y};
        $max_y = $self->{manual_max_y};
    }
    
    # LA MAGIA DE LOS MÁRGENES: La diferencia entre lo que pide el programa
    # y lo que realmente extrajo, genera el espacio en blanco automáticamente.
    my $scale_offset = $self->{offset} - $start;

    my $scale = Market::Panels::Scales->new(
        width        => $width,
        height       => $height,
        min_val      => $min_y,
        max_val      => $max_y,
        visible_bars => $self->{visible_bars},
        offset       => $scale_offset, 
    );

    $self->{price_panel}->set_scale($scale);

    # Obtener el timestamp de la vela inmediatamente anterior al slice visible.
    # Esto permite que draw_time_axis sepa qué día había ANTES de la ventana,
    # y así no trate erróneamente la primera barra visible como "primera del día".
    my $prev_candle_ts = '';
    if ($start > 0) {
        my $prev = $self->{market_data}->get_candle($start - 1);
        $prev_candle_ts = $prev->{timestamp} if defined $prev;
    }

    $self->{price_panel}->render($data_slice, $prev_candle_ts);

    my $vis = $self->{visibility};

    # =========================================================
    # Overlay de Liquidez (BSL / SSL / EQH / EQL / Sweeps)
    # =========================================================
    my $liq_slice = $self->{indicators}->slice_array('Liquidity', $start, $end);
    $self->{liquidity_overlay}->render($scale, $liq_slice, $vis);

    # ========================================================
    # Overlay de Estructuras SMC (BOS / CHOCH / FVG / labels)
    # El flag show_smc actúa como master-switch; los flags
    # individuales dentro de visibility dan control granular.
    # ========================================================
    if ($self->{show_smc}) {
        my $smc_slice = $self->{indicators}->slice_array('SMC_Structures', $start, $end);
        $self->{smc_overlay}->render($scale, $smc_slice, $start, $vis);
    } else {
        $self->{price_canvas}->delete('smc_overlay');
    }

    # =========================================================
    # Overlay ZigZag Fibo
    # =========================================================
    my $zz_fibo_indicator = $self->{indicators}{indicators}{'ZigZag_Fibo'};
    if ($zz_fibo_indicator) {
        $self->{zz_fibo_overlay}->render($scale, $zz_fibo_indicator, $start, $vis);
    }

    # ========================================================
    # Overlay ZigZag (LonesomeTheBlue port)
    # ========================================================
    my $zz_slice = $self->{indicators}->slice_array('ZigZag_Trend', $start, $end);
    $self->{zigzag_overlay}->render($scale, $zz_slice, $start, $vis);

    # ========================================================
    # Overlay Volume Profile (Fase 2 — Sección 7)
    # Cálculo lazy restringido a la ventana visible + contexto
    # ========================================================
    if ($vis->{volume_profile} // 1) {
        my $vp_ind = $self->{indicators}->get('Volume_Profile') if $self->{indicators}->can('get');
        # Recuperar el indicador directamente desde el manager
        my $vp_indicator = $self->{indicators}{indicators}{'Volume_Profile'};
        if (defined $vp_indicator) {
            # Obtener los datos SMC para el modo bos_choch
            my $full_smc = $self->{indicators}->get('SMC_Structures');
            $vp_indicator->calculate_for_window(
                $self->{market_data}, $start, $end, $full_smc
            );
            $self->{vp_overlay}->render($scale, $vp_indicator, $start, $vis);
        }
    } else {
        $self->{price_canvas}->delete('vp_overlay');
    }

    # ========================================================
    # Overlay Anchored VWAP Multi-Pivot (Fase 2 — Sección 8)
    # ========================================================
    if ($vis->{anchored_vwap} // 1) {
        my $vwap_indicator = $self->{indicators}{indicators}{'Anchored_VWAP'};
        if (defined $vwap_indicator) {
            my $full_smc  = $self->{indicators}->get('SMC_Structures');
            my $vp_ind    = $self->{indicators}{indicators}{'Volume_Profile'};
            my $vp_profs  = defined $vp_ind ? $vp_ind->get_profiles() : [];
            $vwap_indicator->calculate_for_window(
                $self->{market_data}, $start, $end, $full_smc, $vp_profs
            );
            $self->{vwap_overlay}->render($scale, $vwap_indicator, $start, $vis);
        }
    } else {
        $self->{price_canvas}->delete('vwap_overlay');
    }

    # ========================================================
    # Overlay ZigZag Volume Profile [ChartPrime] (MPL-2.0)
    # Perfil de volumen anclado a cada tramo del ZigZag
    # ========================================================
    if (($vis->{zvp_zigzag}    // 1)
     || ($vis->{zvp_channel}   // 1)
     || ($vis->{zvp_histogram} // 1)
     || ($vis->{zvp_poc}       // 1)) {
        my $zvp_indicator = $self->{indicators}{indicators}{'ZigZag_VolumeProfile'};
        if (defined $zvp_indicator) {
            $self->{zvp_overlay}->render($scale, $zvp_indicator, $start, $vis);
        }
    } else {
        $self->{price_canvas}->delete('zvp_overlay');
    }

    # ========================================================
    # Overlay MTF Levels (PDH/PDL / PWH/PWL / PMH/PML)
    # ========================================================
    if (($vis->{mtf_daily} // 0)
     || ($vis->{mtf_weekly} // 0)
     || ($vis->{mtf_monthly} // 0)) {
        my $mtf_levels = $self->{market_data}->get_mtf_levels();
        $self->{mtf_overlay}->render($scale, $mtf_levels, $vis);
    } else {
        $self->{price_canvas}->delete('mtf_levels');
    }

    # Panel Secundario (ATR)
    my $atr_width  = $self->{atr_canvas}->width;
    my $atr_height = $self->{atr_canvas}->height;

    my ($atr_min, $atr_max);
    if ($self->{auto_scale_atr}) {
        ($atr_min, $atr_max) = $self->{atr_panel}->get_y_range($atr_slice);
    } else {
        $atr_min = $self->{manual_min_atr};
        $atr_max = $self->{manual_max_atr};
    }

    my $atr_scale = Market::Panels::Scales->new(
        width        => $atr_width,
        height       => $atr_height,
        min_val      => $atr_min,
        max_val      => $atr_max,
        visible_bars => $self->{visible_bars},
        offset       => $scale_offset, 
    );

    $self->{atr_panel}->set_scale($atr_scale);
    $self->{atr_panel}->render($atr_slice);
}

sub bind_events {
    my ($self) = @_;
    # Registra eventos de mouse/teclado [cite: 509, 510]
    
    # Movimiento del ratón para el crosshair
    $self->{price_canvas}->Tk::bind('<Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->_on_mouse_move($ev->x, $ev->y, 'price');
    });

    $self->{atr_canvas}->Tk::bind('<Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->_on_mouse_move($ev->x, $ev->y, 'atr');
    });

    # evitar que la línea se quede "congelada" cuando el ratón sale del canvas
    $self->{price_canvas}->Tk::bind('<Leave>', sub {
        $self->_on_mouse_move(undef, undef, 'price');
    });

    $self->{atr_canvas}->Tk::bind('<Leave>', sub {
        $self->_on_mouse_move(undef, undef, 'atr');
    });

    # =========================================================
    # 1. Zoom Horizontal Normal (Sin teclas, anclado a la derecha)
    # =========================================================
    $self->{price_canvas}->Tk::bind('<Button-4>', sub { 
        $self->_horizontal_zoom(1, 'right'); 
        Tk->break; 
    });
    
    $self->{price_canvas}->Tk::bind('<Button-5>', sub { 
        $self->_horizontal_zoom(-1, 'right'); 
        Tk->break; 
    });

    # =========================================================
    # 2. Zoom Horizontal Fijo al Puntero (Ctrl + Scroll)
    # =========================================================
    $self->{price_canvas}->Tk::bind('<Control-Button-4>', sub { 
        my ($c) = @_; 
        $self->_horizontal_zoom(1, $c->XEvent->x); 
        Tk->break; 
    });
    
    $self->{price_canvas}->Tk::bind('<Control-Button-5>', sub { 
        my ($c) = @_; 
        $self->_horizontal_zoom(-1, $c->XEvent->x); 
        Tk->break; 
    });

    # =========================================================
    # 3. Zoom Vertical de Precios (Shift + Scroll)
    # =========================================================
    $self->{price_canvas}->Tk::bind('<Shift-Button-4>', sub { 
        my ($c) = @_; 
        $self->_vertical_zoom(1, $c->XEvent->y); 
        Tk->break; 
    });
    
    $self->{price_canvas}->Tk::bind('<Shift-Button-5>', sub { 
        my ($c) = @_; 
        $self->_vertical_zoom(-1, $c->XEvent->y); 
        Tk->break; 
    });

    # =========================================================
    # EVENTOS DE ARRASTRE PRINCIPAL (PRECIOS)
    # =========================================================
    $self->{price_canvas}->Tk::bind('<ButtonPress-1>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        # Enviamos la posición X, Y, y el ancho total de la pantalla
        $self->_on_drag_start($ev->x, $ev->y, $c->width);
    });

    $self->{price_canvas}->Tk::bind('<B1-Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->_on_drag_motion($ev->x, $ev->y);
        $self->_on_mouse_move($ev->x, $ev->y, 'price');
    });

    

    # Evento: Clic derecho (Ancla para arrastre vertical)
    $self->{price_canvas}->Tk::bind('<ButtonPress-3>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->{drag_start_y} = $ev->y;
        
    });

    # Evento: Arrastre sostenido con clic derecho
    $self->{price_canvas}->Tk::bind('<B3-Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->_vertical_drag($ev->y);
    });

    # Evento: Doble clic izquierdo (Restablecer vista automática)
    $self->{price_canvas}->Tk::bind('<Double-Button-1>', sub {
        $self->reset_view();
    });

    # =========================================================
    # ARRASTRE HORIZONTAL EN EL PANEL ATR
    # =========================================================
    
    # =========================================================
    # EVENTOS DE ARRASTRE SECUNDARIO (ATR)
    # =========================================================
    $self->{atr_canvas}->Tk::bind('<ButtonPress-1>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        # Si el clic es sobre la escala derecha → modo zoom vertical ATR
        my $escala_sensible = 70;
        if ($ev->x > ($c->width - $escala_sensible)) {
            $self->{drag_mode}    = 'atr_vertical';
            $self->{drag_start_atr} = $ev->y;
            if ($self->{auto_scale_atr}) {
                my ($start, $end) = $self->compute_window();
                my $atr_slice = $self->{indicators}->slice_array('ATR', $start, $end);
                ($self->{manual_min_atr}, $self->{manual_max_atr}) = $self->{atr_panel}->get_y_range($atr_slice);
                $self->{auto_scale_atr} = 0;
            }
        } else {
            $self->_on_drag_start($ev->x, undef, undef);
        }
    });

    $self->{atr_canvas}->Tk::bind('<B1-Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        if (defined $self->{drag_mode} && $self->{drag_mode} eq 'atr_vertical') {
            $self->_vertical_drag_atr($ev->y);
        } else {
            $self->_on_drag_motion($ev->x, undef);
        }
        $self->_on_mouse_move($ev->x, $ev->y, 'atr');
    });

    # Clic derecho en ATR: ancla para zoom vertical con arrastre
    $self->{atr_canvas}->Tk::bind('<ButtonPress-3>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->{drag_start_atr} = $ev->y;

    });

    $self->{atr_canvas}->Tk::bind('<B3-Motion>', sub {
        my ($c) = @_;
        my $ev = $c->XEvent;
        $self->_vertical_drag_atr($ev->y);
    });

    # Doble clic en ATR: restaurar escala automática
    $self->{atr_canvas}->Tk::bind('<Double-Button-1>', sub {
        $self->{auto_scale_atr} = 1;
        $self->request_render();
    });

    # Zoom horizontal en ATR (scroll normal y Ctrl+scroll)
    $self->{atr_canvas}->Tk::bind('<Button-4>', sub {
        $self->_horizontal_zoom(1, 'right');
        Tk->break;
    });

    $self->{atr_canvas}->Tk::bind('<Button-5>', sub {
        $self->_horizontal_zoom(-1, 'right');
        Tk->break;
    });

    $self->{atr_canvas}->Tk::bind('<Control-Button-4>', sub {
        my ($c) = @_;
        $self->_horizontal_zoom(1, $c->XEvent->x);
        Tk->break;
    });

    $self->{atr_canvas}->Tk::bind('<Control-Button-5>', sub {
        my ($c) = @_;
        $self->_horizontal_zoom(-1, $c->XEvent->x);
        Tk->break;
    });

    # Zoom vertical en ATR (Shift+scroll)
    $self->{atr_canvas}->Tk::bind('<Shift-Button-4>', sub {
        my ($c) = @_;
        $self->_vertical_zoom_atr(1, $c->XEvent->y);
        Tk->break;
    });

    $self->{atr_canvas}->Tk::bind('<Shift-Button-5>', sub {
        my ($c) = @_;
        $self->_vertical_zoom_atr(-1, $c->XEvent->y);
        Tk->break;
    });

    # NUEVO: Navegación por teclado (Flechas)
    # =========================================================
    # El bind se hace al MainWindow para capturarlo sin necesidad de dar clic previo
    $self->{mw}->Tk::bind('<Left>',  sub { $self->_pan_horizontal(1); });  # Ver pasado
    $self->{mw}->Tk::bind('<Right>', sub { $self->_pan_horizontal(-1); }); # Ver futuro
    $self->{mw}->Tk::bind('<Up>',    sub { $self->_pan_vertical(-1); });   # Desplazar gráfico arriba
    $self->{mw}->Tk::bind('<Down>',  sub { $self->_pan_vertical(1); });    # Desplazar gráfico abajo


}

sub _on_mouse_move {
    my ($self, $x, $y, $panel_type) = @_;
    
    if ($panel_type eq 'price') {
        # El ratón está en los Precios: Cruz completa aquí, solo vertical en el ATR
        $self->{price_panel}->draw_crosshair($x, $y);
        $self->{atr_panel}->draw_crosshair($x, undef); 
    } else {
        # El ratón está en el ATR: Cruz completa aquí, solo vertical en los Precios
        $self->{atr_panel}->draw_crosshair($x, $y);
        $self->{price_panel}->draw_crosshair($x, undef);
    }
}


sub _on_drag_start {
    my ($self, $x, $y, $width) = @_;
    
    # =========================================================
    # NUEVO: INTERCEPTOR DE SELECCIÓN DE VELA (MODO REPLAY)
    # =========================================================
    if ($self->{awaiting_replay_selection}) {
        # Calcular el ancho de cada vela en píxeles
        my $candle_width = $width / $self->{visible_bars};
        
        # Calcular el índice exacto sumando el offset izquierdo más las velas desplazadas
        my $clicked_idx = int($self->{offset}) + int($x / $candle_width);
        
        # Proteger los límites (evitar clics fuera de rango)
        my $max_idx = $self->{market_data}->size() - 1;
        $clicked_idx = 0 if $clicked_idx < 0;
        $clicked_idx = $max_idx if $clicked_idx > $max_idx;
        
        # Iniciar el replay exactamente en esa vela
        $self->start_replay($clicked_idx);
        return; # Abortar el resto de la función para que no inicie un arrastre
    }

    # =========================================================
    # Resto del código original de _on_drag_start...
    # =========================================================
    my $escala_sensible = 70;
    
    if (defined $width && defined $y && $x > ($width - $escala_sensible)) {
        $self->{drag_mode} = 'vertical';
        $self->{drag_start_y} = $y;
        
        if ($self->{auto_scale_y}) {
            my ($start, $end) = $self->compute_window();
            my $slice = $self->{market_data}->get_slice($start, $end);
            ($self->{manual_min_y}, $self->{manual_max_y}) = $self->{price_panel}->get_y_range($slice);
            $self->{auto_scale_y} = 0; 
        }
    } else {
        $self->{drag_mode} = 'horizontal';
        $self->{drag_start_x} = $x;
        $self->{drag_start_offset} = $self->{offset};
    }
}

sub _on_drag_motion {
    my ($self, $x, $y) = @_;
    
    if ($self->{drag_mode} eq 'vertical') {
        # =============================================
        # LÓGICA DE ESTIRAMIENTO VERTICAL (ZOOM Y)
        # =============================================
        return unless defined $y;
        
        # Distancia en píxeles que moviste el ratón desde el ancla
        my $dy = $y - $self->{drag_start_y};
        my $height = $self->{price_canvas}->height;
        return if $height == 0;
        
        my $current_range = $self->{manual_max_y} - $self->{manual_min_y};
        return if $current_range <= 0;
        
        # Factor de deformación proporcional al rango visible
        my $zoom_factor = ($dy / $height) * $current_range;
        
        # Arrastrar arriba estira los precios (zoom in), abajo los comprime (zoom out)
        $self->{manual_max_y} += $zoom_factor;
        $self->{manual_min_y} -= $zoom_factor;
        
        # Protección de seguridad para evitar que el gráfico se invierta si arrastraste mucho
        if ($self->{manual_max_y} <= $self->{manual_min_y}) {
            $self->{manual_max_y} -= $zoom_factor;
            $self->{manual_min_y} += $zoom_factor;
        }
        
        # Reiniciar el punto de inicio para que el movimiento arrastrado sea fluido fotograma a fotograma
        $self->{drag_start_y} = $y;
        $self->request_render();
        
    } else {
        # =============================================
        # LÓGICA DE PANEO HORIZONTAL (TIEMPO NORMAL)
        # =============================================
        my $dx = $self->{drag_start_x} - $x;
        my $width = $self->{price_canvas}->width;
        return if $width == 0;
        
        my $candle_width = $width / $self->{visible_bars};
        my $fractional_shift = $dx / $candle_width;
        my $new_offset = $self->{drag_start_offset} + $fractional_shift;
        
        if ($new_offset != $self->{offset}) {
            $self->{offset} = $new_offset;
            $self->_clamp_offset(); 
            $self->request_render();
        }
    }
}

sub _vertical_drag {
    my ($self, $y) = @_;
    
    # NUEVO: Abortar inmediatamente si estamos en modo automático
    return if $self->{auto_scale_y};
    
    # ¿Cuántos píxeles se movió el ratón en el eje Y?
    my $dy = $y - $self->{drag_start_y};
    
    my $canvas_height = $self->{price_canvas}->height;
    return if $canvas_height == 0;
    
    # Calcular cuánto "precio" vale 1 píxel actualmente
    my $price_range = $self->{manual_max_y} - $self->{manual_min_y};
    my $price_per_pixel = $price_range / $canvas_height;
    
    my $price_shift = $dy * $price_per_pixel;
    
    $self->{manual_min_y} += $price_shift;
    $self->{manual_max_y} += $price_shift;
    
    $self->{drag_start_y} = $y;
    $self->request_render();
}

sub reset_view {
    my ($self) = @_;
    $self->{auto_scale_y}   = 1;
    $self->{auto_scale_atr} = 1;
    $self->{visible_bars}   = 100;

    my $total_candles = $self->{market_data}->size();
    my $margin = $self->{visible_bars} * 0.15;

    $self->{offset} = $total_candles - $self->{visible_bars} + $margin;
    $self->_clamp_offset();

    $self->request_render();
}

sub set_timeframe {
    my ($self, $tf) = @_;

    $self->{market_data}->set_timeframe($tf);
    $self->{indicators}->reset_all();
    $self->{indicators}->recalculate_all($self->{market_data});

    # reset_view() ahora calcula y se posiciona solo al final de la data
    $self->reset_view();
}

sub _horizontal_zoom {
    my ($self, $delta, $x_or_right) = @_;
    
    # BLOQUEO DE VIEWPORT
    $self->{price_canvas}->yviewMoveto(0);
    $self->{price_canvas}->xviewMoveto(0);
    $self->{atr_canvas}->yviewMoveto(0);
    $self->{atr_canvas}->xviewMoveto(0);
    
    $self->{price_panel}->draw_crosshair(undef, undef);
    $self->{atr_panel}->draw_crosshair(undef, undef);

    my $width = $self->{price_canvas}->width;
    return if $width == 0;

    # EVALUAR EL RATIO: Si es 'right', forzamos el 1.0 (Borde derecho)
    # Si es un número, calculamos la proporción de la pantalla
    my $ratio;
    if ($x_or_right eq 'right') {
        $ratio = 1.0;
    } else {
        $ratio = $x_or_right / $width;
        $ratio = 0 if $ratio < 0;
        $ratio = 1 if $ratio > 1;
    }

    my $old_visible = $self->{visible_bars};
    my $step = 10; 

    # Aplicar el zoom a la cantidad de velas
    if ($delta > 0) {
        $self->{visible_bars} -= $step; # Acercar
    } else {
        $self->{visible_bars} += $step; # Alejar
    }

    $self->{visible_bars} = 10 if $self->{visible_bars} < 10;
    my $max_bars = $self->{market_data}->size();
    $self->{visible_bars} = $max_bars if $self->{visible_bars} > $max_bars && $max_bars > 0;

    # Compensar el offset según el ratio calculado
    my $bar_diff = $old_visible - $self->{visible_bars};
    $self->{offset} += ($bar_diff * $ratio);

    $self->_clamp_offset(); # <-- Usa la nueva función
    $self->request_render();
}

sub _vertical_zoom {
    my ($self, $delta, $y) = @_;
    
    # 1. BLOQUEO DE VIEWPORT
    $self->{price_canvas}->yviewMoveto(0);
    $self->{price_canvas}->xviewMoveto(0);
    $self->{atr_canvas}->yviewMoveto(0);
    $self->{atr_canvas}->xviewMoveto(0);
    
    $self->{price_panel}->draw_crosshair(undef, undef);
    $self->{atr_panel}->draw_crosshair(undef, undef);
    
    if ($self->{auto_scale_y}) {
        my ($start, $end) = $self->compute_window();
        my $slice = $self->{market_data}->get_slice($start, $end);
        ($self->{manual_min_y}, $self->{manual_max_y}) = $self->{price_panel}->get_y_range($slice);
        $self->{auto_scale_y} = 0; 
    }

    my $current_range = $self->{manual_max_y} - $self->{manual_min_y};
    return if $current_range <= 0.0001; 

    # --- NUEVA MATEMÁTICA DE ZOOM ANCLADO ---
    
    my $height = $self->{price_canvas}->height;
    return if $height == 0;

    # Calculamos la proporción del ratón en la pantalla (0.0 es el techo, 1.0 es el piso)
    my $ratio = $y / $height;
    
    # Protegemos los límites por si el cursor está justo en el borde exterior
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;

    my $zoom_factor = 0.05;
    my $zoom_amount = $current_range * $zoom_factor;

    if ($delta > 0) {
        # Acercar (Estirar) -> Reducimos el rango total
        # Al techo (max_y) le quitamos la parte proporcional de arriba
        $self->{manual_max_y} -= $zoom_amount * $ratio;
        # Al piso (min_y) le sumamos el resto proporcional de abajo
        $self->{manual_min_y} += $zoom_amount * (1 - $ratio);
    } else {
        # Alejar (Aplastar) -> Aumentamos el rango total
        $self->{manual_max_y} += $zoom_amount * $ratio;
        $self->{manual_min_y} -= $zoom_amount * (1 - $ratio);
    }

    $self->request_render();
}
# ==============================================================================
# NUEVAS FUNCIONES: Auto/Manual y Paneo por Teclado
# ==============================================================================

sub toggle_auto_scale {
    my ($self) = @_;
    
    if ($self->{auto_scale_y}) {
        # Si estaba en automático, pasamos a manual congelando el rango visual actual
        my ($start, $end) = $self->compute_window();
        my $slice = $self->{market_data}->get_slice($start, $end);
        ($self->{manual_min_y}, $self->{manual_max_y}) = $self->{price_panel}->get_y_range($slice);
        
        $self->{auto_scale_y} = 0; # Cambiar a Manual
    } else {
        # Si estaba en manual, volvemos a automático
        $self->{auto_scale_y} = 1;
    }
    
    $self->request_render();
    return $self->{auto_scale_y};
}

sub _pan_horizontal {
    my ($self, $direction) = @_;
    
    # Nos movemos un 10% de la cantidad de velas que se ven en pantalla
    my $step = $self->{visible_bars} * 0.1;
    $step = 1 if $step < 1; # Mínimo moverse 1 vela
    
    my $new_offset = $self->{offset} + ($direction * $step);
    
    if ($new_offset != $self->{offset}) {
        $self->{offset} = $new_offset;
        $self->_clamp_offset(); # <-- Usa la nueva función
        $self->request_render();
    }
}

sub _pan_vertical {
    my ($self, $direction) = @_;
    
    # El paneo vertical (arriba/abajo) solo tiene sentido si estamos en MODO MANUAL
    return if $self->{auto_scale_y};
    
    my $rango = $self->{manual_max_y} - $self->{manual_min_y};
    
    # Desplazamos la vista un 10% del rango de precios actual
    my $shift = $rango * 0.1 * $direction;
    
    $self->{manual_min_y} += $shift;
    $self->{manual_max_y} += $shift;
    
    $self->request_render();
}

sub _vertical_zoom_atr {
    my ($self, $delta, $y) = @_;

    $self->{atr_canvas}->yviewMoveto(0);
    $self->{atr_canvas}->xviewMoveto(0);
    $self->{atr_panel}->draw_crosshair(undef, undef);

    if ($self->{auto_scale_atr}) {
        my ($start, $end) = $self->compute_window();
        my $atr_slice = $self->{indicators}->slice_array('ATR', $start, $end);
        ($self->{manual_min_atr}, $self->{manual_max_atr}) = $self->{atr_panel}->get_y_range($atr_slice);
        $self->{auto_scale_atr} = 0;
    }

    my $current_range = $self->{manual_max_atr} - $self->{manual_min_atr};
    return if $current_range <= 0.0001;

    my $height = $self->{atr_canvas}->height;
    return if $height == 0;

    my $ratio = $y / $height;
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;

    my $zoom_amount = $current_range * 0.05;

    if ($delta > 0) {
        $self->{manual_max_atr} -= $zoom_amount * $ratio;
        $self->{manual_min_atr} += $zoom_amount * (1 - $ratio);
    } else {
        $self->{manual_max_atr} += $zoom_amount * $ratio;
        $self->{manual_min_atr} -= $zoom_amount * (1 - $ratio);
    }

    $self->request_render();
}

sub _vertical_drag_atr {
    my ($self, $y) = @_;

    my $dy = $y - $self->{drag_start_atr};
    my $canvas_height = $self->{atr_canvas}->height;
    return if $canvas_height == 0;

    my $price_range = $self->{manual_max_atr} - $self->{manual_min_atr};
    return if $price_range <= 0;

    my $value_per_pixel = $price_range / $canvas_height;
    my $shift = $dy * $value_per_pixel;

    $self->{manual_min_atr} += $shift;
    $self->{manual_max_atr} += $shift;

    $self->{drag_start_atr} = $y;
    $self->request_render();
}

sub _clamp_offset {
    my ($self) = @_;
    my $total_candles = $self->{market_data}->size();
    
    # Límite Izquierdo: Mantenemos el margen del 15% para cuando llegas al inicio del pasado
    my $margin_left = $self->{visible_bars} * 0.15; 
    my $min_offset = -$margin_left;
    
    # NUEVO LÍMITE DERECHO: 
    # Permitimos que la gráfica se desplace hasta que la vela número 0 de la pantalla
    # sea la penúltima vela de la data. Esto deja solo 2 velas pegadas a la izquierda.
    my $max_offset = $total_candles - 2;
    
    # Protección de seguridad por si el archivo carga con menos de 2 velas
    $max_offset = 0 if $max_offset < 0;
    
    # Evaluar qué valor es el techo y cuál es el piso
    my $lower_bound = $min_offset < $max_offset ? $min_offset : $max_offset;
    my $upper_bound = $min_offset > $max_offset ? $min_offset : $max_offset;
    
    # Aplicar el bloqueo (Clamp) al desplazamiento actual
    $self->{offset} = $lower_bound if $self->{offset} < $lower_bound;
    $self->{offset} = $upper_bound if $self->{offset} > $upper_bound;
}

# ==============================================================================
# SISTEMA REPLAY: Motor de Eventos y Callbacks
# ==============================================================================

sub enable_replay_selection {
    my ($self) = @_;
    # Activar la bandera de espera
    $self->{awaiting_replay_selection} = 1;
    # Feedback visual: Cambiamos el cursor del ratón a una cruz
    $self->{price_canvas}->configure(-cursor => 'crosshair');
    print "Modo Replay Seleccion: Haz clic sobre la vela donde deseas iniciar el corte.\n";
}

sub start_replay {
    my ($self, $index) = @_;
    
    # Limpiar el estado de espera y devolver el cursor a la normalidad
    $self->{awaiting_replay_selection} = 0;
    $self->{price_canvas}->configure(-cursor => 'arrow');

    # Enviar el índice exacto clickeado al backend de datos
    $self->{market_data}->start_replay($index);
    
    # Recalcular indicadores hasta el corte
    $self->{indicators}->reset_all();
    $self->{indicators}->recalculate_all($self->{market_data});
    
    $self->reset_view();
}

sub stop_replay {
    my ($self) = @_;
    $self->pause_replay();
    $self->{market_data}->stop_replay();
    
    # Al salir, recalculamos todos los indicadores con la data entera
    $self->{indicators}->reset_all();
    $self->{indicators}->recalculate_all($self->{market_data});
    
    $self->reset_view();
}

sub step_replay {
    my ($self, $steps) = @_;
    return unless $self->{market_data}->{replay_mode};

    $self->{market_data}->step_replay($steps);
    
    # Los indicadores y overlays se recalcularán dinámicamente hasta la última vela visible
    $self->{indicators}->reset_all();
    $self->{indicators}->recalculate_all($self->{market_data});
    
    # Auto-Desplazamiento (Auto-Scroll) si el precio en replay llega al borde de la pantalla
    my $current_last = $self->{market_data}->size() - 1;
    my $visible_end = $self->{offset} + $self->{visible_bars};
    
    if ($current_last >= $visible_end - 5) {
        $self->{offset} += $steps;
        $self->_clamp_offset();
    }
    
    $self->request_render();
}

sub play_replay {
    my ($self) = @_;
    return if $self->{replay_timer};
    $self->{replay_speed} = 1000; # Velocidad Normal: 1 segundo por vela
    $self->_replay_loop();
}

sub fast_forward_replay {
    my ($self) = @_;
    $self->{replay_speed} = 150; # Velocidad Rápida: 150 milisegundos por vela
    $self->_replay_loop() unless $self->{replay_timer};
}

sub pause_replay {
    my ($self) = @_;
    if ($self->{replay_timer}) {
        $self->{replay_timer}->cancel;
        $self->{replay_timer} = undef;
    }
}

sub _replay_loop {
    my ($self) = @_;
    $self->step_replay(1);
    
    # Creamos un bucle asíncrono utilizando el planificador de eventos after() de Perl/Tk
    $self->{replay_timer} = $self->{mw}->after($self->{replay_speed}, sub {
        $self->_replay_loop();
    });
}
sub toggle_smc {
    my ($self) = @_;
    $self->{show_smc} = $self->{show_smc} ? 0 : 1;
    # Sincronizar con los flags individuales de SMC en visibility
    for my $key (qw(bos_choch structure_labels fvg)) {
        $self->{visibility}{$key} = $self->{show_smc};
        if (my $btn = $self->{_sidebar_buttons}{$key}) {
            $self->_update_button_state($btn, $self->{show_smc});
        }
    }
    $self->request_render();
    return $self->{show_smc};
}

# =============================================================================
# SISTEMA DE VISIBILIDAD GRANULAR
# =============================================================================

# toggle_visibility($key): conmuta un flag individual y redibuja.
# Actualiza el color del botón de la barra lateral si existe.
sub toggle_visibility {
    my ($self, $key) = @_;
    my $new_val = $self->{visibility}{$key} ? 0 : 1;
    $self->{visibility}{$key} = $new_val;
    if (my $btn = $self->{_sidebar_buttons}{$key}) {
        $self->_update_button_state($btn, $new_val);
    }
    $self->request_render();
    return $new_val;
}

# _update_button_state: actualiza el color del botón según su estado on/off.
sub _update_button_state {
    my ($self, $btn, $is_on) = @_;
    if ($is_on) {
        $btn->configure(-bg => '#2962FF', -fg => '#FFFFFF',
                        -activebackground => '#1E4FD8');
    } else {
        $btn->configure(-bg => '#2A2E39', -fg => '#6B7280',
                        -activebackground => '#383D4A');
    }
}

# =============================================================================
# BARRA LATERAL DE CONTROLES (estilo VS Code)
# =============================================================================
# Recibe un Frame de Tk ya creado en market.pl y lo popula con botones toggle.
# Cada sección agrupa controles relacionados con una etiqueta separadora.
sub _build_sidebar {
    my ($self, $sidebar) = @_;
    return unless defined $sidebar;

    my $bg_panel  = '#1A1E2E';   # fondo del panel
    my $bg_on     = '#2962FF';   # botón activo  (azul TradingView)
    my $bg_off    = '#2A2E39';   # botón inactivo
    my $fg_on     = '#FFFFFF';
    my $fg_off    = '#6B7280';
    my $fg_label  = '#4B5563';
    my $btn_font  = 'Helvetica 9';
    my $lbl_font  = 'Helvetica 8';

    $sidebar->configure(-bg => $bg_panel);

    # --- Cierre de sección ---
    my $sep = sub {
        my ($text) = @_;
        $sidebar->Label(
            -text => $text, -bg => $bg_panel, -fg => $fg_label,
            -font => $lbl_font, -anchor => 'w',
        )->pack(-fill => 'x', -padx => 6, -pady => [10, 2]);
        $sidebar->Frame(-bg => '#2D3245', -height => 1)
            ->pack(-fill => 'x', -padx => 4, -pady => [0, 4]);
    };

    # --- Botón toggle reutilizable ---
    my $make_toggle = sub {
        my ($key, $label) = @_;
        my $is_on = $self->{visibility}{$key} // 1;
        my $btn;
        $btn = $sidebar->Button(
            -text             => $label,
            -bg               => $is_on ? $bg_on : $bg_off,
            -fg               => $is_on ? $fg_on : $fg_off,
            -activebackground => $is_on ? '#1E4FD8' : '#383D4A',
            -activeforeground => '#FFFFFF',
            -relief           => 'flat',
            -anchor           => 'w',
            -font             => $btn_font,
            -padx             => 8,
            -pady             => 4,
            -cursor           => 'hand2',
            -command          => sub { $self->toggle_visibility($key) },
        );
        $btn->pack(-fill => 'x', -padx => 4, -pady => 1);
        $self->{_sidebar_buttons}{$key} = $btn;
    };

    # --- Botón de acción simple (sin toggle de visibilidad) ---
    my $make_action = sub {
        my ($label, $cmd) = @_;
        $sidebar->Button(
            -text             => $label,
            -bg               => $bg_off,
            -fg               => '#D1D4DC',
            -activebackground => '#383D4A',
            -activeforeground => '#FFFFFF',
            -relief           => 'flat',
            -anchor           => 'w',
            -font             => $btn_font,
            -padx             => 8,
            -pady             => 4,
            -cursor           => 'hand2',
            -command          => $cmd,
        )->pack(-fill => 'x', -padx => 4, -pady => 1);
    };

    # ── Sección: SMC Pro [Neon] — Estructura Swing ───────────
    $sep->('SMC Pro — Swing');
    $make_toggle->('bos_choch',        'BB  BOS / CHoCH');
    $make_toggle->('structure_labels', 'HH  HH / HL / LH / LL');
    $make_toggle->('strong_weak_hl',   'SW  Strong / Weak H&L');
    $make_toggle->('order_blocks',     'OB  Order Blocks');

    # ── Sección: SMC Pro [Neon] — Estructura Interna ─────────
    $sep->('SMC Pro — Interno');
    $make_toggle->('int_bos_choch',        'iB  BOS / CHoCH (i)');
    $make_toggle->('int_structure_labels', 'iH  HH / HL (i)');
    $make_toggle->('int_order_blocks',     'iO  Order Blocks (i)');

    # ── Sección: SMC Pro [Neon] — Zonas ──────────────────────
    $sep->('SMC Pro — Zonas');
    $make_toggle->('fvg',              'FV  Fair Value Gap');
    $make_toggle->('eq_highs_lows',    'EQ  EQH / EQL');
    $make_toggle->('premium_discount', 'PD  Premium / Discount');

    # ── Sección: ZigZag ──────────────────────────────────────
    $sep->('ZigZag');
    $make_toggle->('zigzag',           'ZZ  ZigZag');

    # ── Sección: Liquidez ────────────────────────────────────
    $sep->('Liquidez');
    $make_toggle->('bsl',              'UP  Buy-Side (BSL)');
    $make_toggle->('ssl',              'DN  Sell-Side (SSL)');
    $make_toggle->('eqh_eql',         'EQ  EQH / EQL (Liq)');
    $make_toggle->('liq_events',       'SW  Sweeps / Grabs');

    # ── Sección: Volume Profile (Fase 2) ─────────────────────
    $sep->('Perfil de Volumen');
    $make_toggle->('volume_profile',   'VP  Vol Profile ON/OFF');
    $make_toggle->('vp_histogram',     '::  Histograma VP');
    $make_toggle->('vp_poc',           'PC  Línea POC');
    $make_toggle->('vp_va',            'VA  VAH / VAL');

    # ── Sección: Anchored VWAP (Fase 2) ──────────────────────
    $sep->('VWAP Anclado');
    $make_toggle->('anchored_vwap',    'VW  VWAP ON/OFF');
    $make_toggle->('vwap_markers',     'MM  Marcadores Ancla');
    $make_toggle->('vwap_labels',      'LL  Etiquetas VWAP');

    # ── Sección: MTF Levels ──────────────────────────────────────────────────
    $sep->('MTF Levels');
    $make_toggle->('mtf_daily',        'DH  Show Daily H/L');
    $make_toggle->('mtf_weekly',       'WH  Show Weekly H/L');
    $make_toggle->('mtf_monthly',      'MH  Show Monthly H/L');
    $make_action->('\x{2699}  Configurar MTF', sub { $self->_open_mtf_levels_config() });

    # ── Sección: ZZ Volume Profile [ChartPrime] ───────────
    $sep->('ZZ Volume Profile');
    $make_toggle->('zvp_zigzag',       'ZZ  ZZ Lineas');
    $make_toggle->('zvp_channel',      'CH  Canal ATR');
    $make_toggle->('zvp_histogram',    'HH  Histograma Vol');
    $make_toggle->('zvp_poc',          'PC  POC por Tramo');
    $make_action->('\x{2699}  Configurar ZVP', sub { $self->_open_zvp_config() });

    # ── Sección: Fibonacci ───────────────────────────────────
    $sep->('Fibonacci');
    $make_toggle->('fibo_zigzag',      'FIB ZigZag');
    $make_toggle->('fibo_levels',      'FIB Levels');
    $make_action->('\x{2699}  Configurar Fibo', sub { $self->_open_zz_fibo_config() });

    # ── Sección: Replay ──────────────────────────────────────
    $sep->('Replay');
    $make_action->('[<] Paso atras',  sub { $self->step_replay(-1)  });
    $make_action->('[>] Play',        sub { $self->play_replay()     });
    $make_action->('[||] Pausa',      sub { $self->pause_replay()    });
    $make_action->('[>>] Paso fwd',   sub { $self->step_replay(1)    });
}

# =============================================================================
# _open_zvp_config — Diálogo de configuración del ZigZag Volume Profile
# Equivalente al menú "Entradas de datos" de TradingView para este indicador
# =============================================================================
sub _open_zvp_config {
    my ($self) = @_;

    my $zvp_ind = $self->{indicators}{indicators}{'ZigZag_VolumeProfile'};
    unless (defined $zvp_ind) {
        $self->{mw}->messageBox(
            -title   => 'ZVP Config',
            -message => 'El indicador ZigZag_VolumeProfile no está registrado.',
            -type    => 'OK',
        );
        return;
    }

    # Colores del tema
    my $bg        = '#131722';
    my $bg_panel  = '#1A1E2E';
    my $bg_field  = '#2A2E39';
    my $fg        = '#D1D4DC';
    my $fg_label  = '#8892A4';
    my $accent    = '#2962FF';
    my $fg_group  = '#4B5563';
    my $font_lbl  = 'Helvetica 10';
    my $font_grp  = 'Helvetica 8';
    my $font_btn  = 'Helvetica 10 bold';

    # Diálogo principal
    my $top = $self->{mw}->Toplevel;
    $top->title('ZigZag Volume Profile [ChartPrime]');
    $top->configure(-bg => $bg);
    $top->resizable(0, 0);

    # Centrar sobre la ventana principal
    my $pw = $self->{mw}->width;
    my $ph = $self->{mw}->height;
    my $px = $self->{mw}->x;
    my $py = $self->{mw}->y;
    $top->geometry(sprintf("+%d+%d", $px + int(($pw - 440)/2), $py + int(($ph - 520)/2)));

    # Título del diálogo
    $top->Label(
        -text => 'ZigZag Volume Profile [ChartPrime]',
        -bg   => $bg, -fg => $fg,
        -font => 'Helvetica 12 bold',
        -anchor => 'w',
    )->pack(-fill => 'x', -padx => 16, -pady => [14, 4]);

    # Línea separadora
    $top->Frame(-bg => '#2D3245', -height => 1)->pack(-fill => 'x', -padx => 8, -pady => [0, 8]);

    # Frame de contenido con scroll
    my $content = $top->Frame(-bg => $bg)->pack(-fill => 'both', -expand => 1, -padx => 8);

    # -------------------------------------------------------------------------
    # Helper: fila de parámetro (label + widget)
    # -------------------------------------------------------------------------
    my $make_row = sub {
        my ($parent, $label_text, $widget_cb) = @_;
        my $row = $parent->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text   => $label_text,
            -bg     => $bg, -fg => $fg,
            -font   => $font_lbl,
            -anchor => 'w',
            -width  => 30,
        )->pack(-side => 'left', -padx => [0, 8]);
        $widget_cb->($row);
    };

    # Helper: separador de grupo
    my $make_group = sub {
        my ($parent, $text) = @_;
        $parent->Label(
            -text   => uc($text),
            -bg     => $bg, -fg => $fg_group,
            -font   => $font_grp,
            -anchor => 'w',
        )->pack(-fill => 'x', -padx => 0, -pady => [12, 2]);
        $parent->Frame(-bg => '#2D3245', -height => 1)->pack(-fill => 'x', -pady => [0, 6]);
    };

    # Helper: Spinbox estético
    my $make_spin = sub {
        my ($parent, $var_ref, $from, $to, $inc) = @_;
        $inc //= 1;
        my $sp = $parent->Spinbox(
            -textvariable => $var_ref,
            -from         => $from,
            -to           => $to,
            -increment    => $inc,
            -width        => 8,
            -bg           => $bg_field,
            -fg           => $fg,
            -insertbackground => $fg,
            -buttonbackground => $bg_field,
            -relief       => 'flat',
            -font         => $font_lbl,
        );
        $sp->pack(-side => 'right');
        return $sp;
    };

    # Helper: botón de color
    my $make_color_btn = sub {
        my ($parent, $col_ref) = @_;
        my $btn;
        $btn = $parent->Button(
            -bg               => $$col_ref,
            -activebackground => $$col_ref,
            -width            => 3,
            -relief           => 'flat',
            -cursor           => 'hand2',
            -command          => sub {
                my $new_col = $top->chooseColor(
                    -initialcolor => $$col_ref,
                    -title        => 'Elegir color',
                );
                if (defined $new_col) {
                    $$col_ref = $new_col;
                    $btn->configure(-bg => $new_col, -activebackground => $new_col);
                }
            },
        );
        $btn->pack(-side => 'right', -padx => 2);
        return $btn;
    };

    # =========================================================================
    # Variables vinculadas a los parámetros actuales del indicador / overlay
    # =========================================================================
    my $v_profiles  = $zvp_ind->{max_profiles};
    my $v_swing_len = $zvp_ind->{swing_length};
    my $v_chan_w    = $zvp_ind->{channel_width};
    my $v_bins      = $zvp_ind->{volume_bin_count} * 2;   # Pine muestra el doble
    my $v_bin_w     = $self->{zvp_overlay}{bin_width_px};
    my $v_poc_w     = $self->{zvp_overlay}{poc_width};
    my $v_col_low   = $self->{zvp_overlay}{color_bin_low};
    my $v_col_high  = $self->{zvp_overlay}{color_bin_high};
    my $v_col_poc   = $self->{zvp_overlay}{color_poc};

    # =========================================================================
    # GENERAL
    # =========================================================================
    $make_row->($content,
        'Amount of ZigZag Volume Profiles to display',
        sub { $make_spin->($_[0], \$v_profiles, 1, 20, 1) },
    );

    # =========================================================================
    # SWING CHANNEL
    # =========================================================================
    $make_group->($content, 'Swing Channel');

    # Display (checkbox ligado al flag de visibilidad zvp_channel)
    {
        my $row = $content->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text => 'Display', -bg => $bg, -fg => $fg,
            -font => $font_lbl, -anchor => 'w', -width => 30,
        )->pack(-side => 'left');
        my $chk_var = $self->{visibility}{zvp_channel} ? 1 : 0;
        $row->Checkbutton(
            -variable         => \$chk_var,
            -bg               => $bg,
            -activebackground => $bg,
            -selectcolor      => $accent,
            -relief           => 'flat',
            -command => sub {
                $self->{visibility}{zvp_channel} = $chk_var;
                $self->request_render();
            },
        )->pack(-side => 'right');
    }

    $make_row->($content, 'Longitud',
        sub { $make_spin->($_[0], \$v_swing_len, 2, 500, 1) },
    );
    $make_row->($content, 'Width',
        sub { $make_spin->($_[0], \$v_chan_w, 0.3, 2.0, 0.1) },
    );

    # =========================================================================
    # VOLUMEPROFILE
    # =========================================================================
    $make_group->($content, 'VolumeProfile');

    # Display (checkbox ligado al flag zvp_histogram)
    {
        my $row = $content->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text => 'Display', -bg => $bg, -fg => $fg,
            -font => $font_lbl, -anchor => 'w', -width => 30,
        )->pack(-side => 'left');
        my $chk_var = $self->{visibility}{zvp_histogram} ? 1 : 0;
        $row->Checkbutton(
            -variable         => \$chk_var,
            -bg               => $bg,
            -activebackground => $bg,
            -selectcolor      => $accent,
            -relief           => 'flat',
            -command => sub {
                $self->{visibility}{zvp_histogram} = $chk_var;
                $self->request_render();
            },
        )->pack(-side => 'right');
    }

    $make_row->($content, 'Bins',
        sub { $make_spin->($_[0], \$v_bins, 2, 20, 2) },
    );
    $make_row->($content, 'Bins Width',
        sub { $make_spin->($_[0], \$v_bin_w, 1, 20, 1) },
    );

    # Fila de colores (bin_low y bin_high, igual que TradingView)
    {
        my $row = $content->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text => 'Colors (Low / High)',
            -bg   => $bg, -fg => $fg,
            -font => $font_lbl, -anchor => 'w', -width => 30,
        )->pack(-side => 'left');
        $make_color_btn->($row, \$v_col_high);
        $make_color_btn->($row, \$v_col_low);
    }

    # =========================================================================
    # POC
    # =========================================================================
    $make_group->($content, 'PoC');

    # Display (checkbox ligado al flag zvp_poc)
    {
        my $row = $content->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text => 'Display', -bg => $bg, -fg => $fg,
            -font => $font_lbl, -anchor => 'w', -width => 30,
        )->pack(-side => 'left');
        my $chk_var = $self->{visibility}{zvp_poc} ? 1 : 0;
        $row->Checkbutton(
            -variable         => \$chk_var,
            -bg               => $bg,
            -activebackground => $bg,
            -selectcolor      => $accent,
            -relief           => 'flat',
            -command => sub {
                $self->{visibility}{zvp_poc} = $chk_var;
                $self->request_render();
            },
        )->pack(-side => 'right');
    }

    $make_row->($content, 'PoC Line Width',
        sub { $make_spin->($_[0], \$v_poc_w, 1, 5, 1) },
    );

    {
        my $row = $content->Frame(-bg => $bg)->pack(-fill => 'x', -pady => 4);
        $row->Label(
            -text => 'PoC Color',
            -bg   => $bg, -fg => $fg,
            -font => $font_lbl, -anchor => 'w', -width => 30,
        )->pack(-side => 'left');
        $make_color_btn->($row, \$v_col_poc);
    }

    # =========================================================================
    # Botones Cancelar / Aceptar
    # =========================================================================
    $top->Frame(-bg => '#2D3245', -height => 1)->pack(-fill => 'x', -padx => 8, -pady => [12, 0]);

    my $btn_frame = $top->Frame(-bg => $bg)->pack(-fill => 'x', -padx => 16, -pady => 10);

    $btn_frame->Button(
        -text             => 'Cancelar',
        -bg               => $bg_field,
        -fg               => $fg,
        -activebackground => '#383D4A',
        -activeforeground => '#FFFFFF',
        -relief           => 'flat',
        -font             => $font_btn,
        -padx             => 16,
        -pady             => 6,
        -cursor           => 'hand2',
        -command          => sub { $top->destroy() },
    )->pack(-side => 'right', -padx => [8, 0]);

    $btn_frame->Button(
        -text             => 'Aceptar',
        -bg               => $accent,
        -fg               => '#FFFFFF',
        -activebackground => '#1E4FD8',
        -activeforeground => '#FFFFFF',
        -relief           => 'flat',
        -font             => $font_btn,
        -padx             => 16,
        -pady             => 6,
        -cursor           => 'hand2',
        -command          => sub {
            # ── Aplicar parámetros al indicador ──────────────────────────
            my $new_profiles  = int($v_profiles  + 0.5);
            my $new_swing_len = int($v_swing_len + 0.5);
            my $new_chan_w    = $v_chan_w + 0;
            my $new_bins      = int(int($v_bins + 0.5) / 2);   # Pine: int(input/2)
            my $new_bin_w     = int($v_bin_w + 0.5);
            my $new_poc_w     = int($v_poc_w + 0.5);

            # Validaciones mínimas
            $new_profiles  = 1   if $new_profiles  < 1;
            $new_profiles  = 20  if $new_profiles  > 20;
            $new_swing_len = 2   if $new_swing_len < 2;
            $new_swing_len = 500 if $new_swing_len > 500;
            $new_bins      = 1   if $new_bins      < 1;
            $new_bins      = 10  if $new_bins      > 10;
            $new_chan_w    = 0.3 if $new_chan_w    < 0.3;
            $new_chan_w    = 2.0 if $new_chan_w    > 2.0;

            # Solo recalcula si cambió algo que afecta al cálculo
            my $needs_recalc =
                $zvp_ind->{max_profiles}     != $new_profiles  ||
                $zvp_ind->{swing_length}     != $new_swing_len ||
                $zvp_ind->{volume_bin_count} != $new_bins      ||
                abs($zvp_ind->{channel_width} - $new_chan_w) > 0.001;

            $zvp_ind->{max_profiles}     = $new_profiles;
            $zvp_ind->{swing_length}     = $new_swing_len;
            $zvp_ind->{channel_width}    = $new_chan_w;
            $zvp_ind->{volume_bin_count} = $new_bins;

            # Actualizar overlay
            $self->{zvp_overlay}{bin_width_px}  = $new_bin_w;
            $self->{zvp_overlay}{poc_width}     = $new_poc_w;
            $self->{zvp_overlay}{color_bin_low}  = $v_col_low;
            $self->{zvp_overlay}{color_bin_high} = $v_col_high;
            $self->{zvp_overlay}{color_poc}      = $v_col_poc;

            if ($needs_recalc) {
                $zvp_ind->reset();
                $zvp_ind->calculate_batch($self->{market_data});
            }

            $self->request_render();
            $top->destroy();
        },
    )->pack(-side => 'right');
}

sub _open_zz_fibo_config {
    my ($self) = @_;

    my $zz_fibo_ind = $self->{indicators}{indicators}{'ZigZag_Fibo'};
    unless (defined $zz_fibo_ind) {
        $self->{mw}->messageBox(
            -title   => 'ZZ Fibo Config',
            -message => 'El indicador ZigZag_Fibo no está registrado.',
            -type    => 'OK',
        );
        return;
    }

    # Colores del tema (Estilo anterior/oscuro)
    my $bg        = '#131722';
    my $bg_panel  = '#1A1E2E';
    my $bg_field  = '#2A2E39';
    my $fg        = '#D1D4DC';
    my $fg_label  = '#8892A4';
    my $accent    = '#2962FF';
    
    my $top = $self->{mw}->Toplevel(-bg => $bg);
    $top->title("ZZMTF");
    $top->geometry("420x200");
    $top->transient($self->{mw});
    $top->grab();

    my $content = $top->Frame(-bg => $bg_panel)->pack(-fill => 'both', -expand => 1, -padx => 15, -pady => 15);
    
    my $make_row = sub {
        my ($parent, $label_text, $widget_cb) = @_;
        my $f = $parent->Frame(-bg => $bg_panel)->pack(-fill => 'x', -pady => 6);
        $f->Label(-text => $label_text, -bg => $bg_panel, -fg => $fg_label, -anchor => 'w', -width => 25)
          ->pack(-side => 'left');
        my $w = $widget_cb->($f);
        $w->pack(-side => 'right', -fill => 'x', -expand => 1, -padx => [10, 0]);
        return $f;
    };
    
    my $make_spin = sub {
        my ($parent, $var_ref, $from, $to, $inc) = @_;
        return $parent->Spinbox(
            -textvariable => $var_ref,
            -from => $from, -to => $to, -increment => $inc,
            -bg => $bg_field, -fg => $fg,
            -buttonbackground => $bg_field,
            -relief => 'flat', -highlightthickness => 1, -highlightbackground => $bg_field,
            -width => 10
        );
    };

    my $v_prd = $zz_fibo_ind->{prd};
    my $v_tf  = $zz_fibo_ind->{tf} // '1h';

    $make_row->($content,
        'ZigZag Period',
        sub { $make_spin->($_[0], \$v_prd, 1, 30, 1) },
    );

    # Fila de botones para Timeframe (Ahora "ZigZag Resolution")
    my $tf_frame = $content->Frame(-bg => $bg_panel)->pack(-fill => 'x', -pady => 15);
    $tf_frame->Label(-text => 'ZigZag Resolution', -bg => $bg_panel, -fg => $fg_label, -anchor => 'w', -width => 15)
      ->pack(-side => 'left');
    
    my $tf_btn_frame = $tf_frame->Frame(-bg => $bg_panel)->pack(-side => 'right', -fill => 'x', -expand => 1);
    
    my @tf_options = ('1m', '5m', '15m', '1h', '2h', '4h', 'D', 'W');
    my %tf_btns;
    
    my $update_tf_btns = sub {
        for my $opt (@tf_options) {
            if ($v_tf eq $opt) {
                $tf_btns{$opt}->configure(-bg => $accent, -fg => '#FFFFFF');
            } else {
                $tf_btns{$opt}->configure(-bg => $bg_field, -fg => $fg);
            }
        }
    };

    for my $opt (@tf_options) {
        $tf_btns{$opt} = $tf_btn_frame->Button(
            -text => $opt,
            -bg => $bg_field, -fg => $fg, -relief => 'flat',
            -activebackground => $accent, -activeforeground => '#FFFFFF',
            -command => sub {
                $v_tf = $opt;
                $update_tf_btns->();
            }
        )->pack(-side => 'left', -padx => 2, -fill => 'x', -expand => 1);
    }
    
    $update_tf_btns->();

    # Botones Aceptar / Cancelar
    my $btn_frame = $top->Frame(-bg => $bg)->pack(-fill => 'x', -padx => 15, -pady => 15);
    
    $btn_frame->Button(
        -text => 'Cancelar', -bg => $bg_field, -fg => $fg, -relief => 'flat',
        -command => sub { $top->destroy() }
    )->pack(-side => 'left', -padx => [0, 10]);

    $btn_frame->Button(
        -text => 'Aceptar', -bg => $accent, -fg => '#FFFFFF', -relief => 'flat',
        -command => sub {
            my $new_prd = $v_prd + 0;
            
            if ($zz_fibo_ind->{prd} != $new_prd || $zz_fibo_ind->{tf} ne $v_tf) {
                $zz_fibo_ind->{prd} = $new_prd;
                $zz_fibo_ind->{tf} = $v_tf;
                $zz_fibo_ind->reset();
                $zz_fibo_ind->calculate_batch($self->{market_data});
                $self->request_render();
            }
            $top->destroy();
        },
    )->pack(-side => 'right');
}

# =============================================================================
# _open_mtf_levels_config — Diálogo de configuración de MTF Levels
# Permite cambiar colores y estilo de línea para Daily, Weekly y Monthly.
# Estilo del menú: igual al resto de la aplicación (tema oscuro).
# =============================================================================
sub _open_mtf_levels_config {
    my ($self) = @_;

    my $ovl = $self->{mtf_overlay};

    my $bg        = '#131722';
    my $bg_panel  = '#1A1E2E';
    my $bg_field  = '#2A2E39';
    my $fg        = '#D1D4DC';
    my $fg_label  = '#8892A4';
    my $accent    = '#2962FF';

    my $top = $self->{mw}->Toplevel(-bg => $bg);
    $top->title('MTF Levels');
    $top->geometry('460x280');
    $top->transient($self->{mw});
    $top->grab();

    # Título
    $top->Label(
        -text   => 'MTF Levels — Configuración',
        -bg     => $bg, -fg => $fg,
        -font   => 'Helvetica 12 bold',
        -anchor => 'w',
    )->pack(-fill => 'x', -padx => 16, -pady => [14, 4]);

    my $content = $top->Frame(-bg => $bg_panel)->pack(-fill => 'both', -expand => 1, -padx => 12, -pady => 8);

    my @styles  = ('SOLID', 'DASHED', 'DOTTED');

    # --- Fila helper: Etiqueta | Selector de estilo ---
    my $make_row = sub {
        my ($parent, $label, $style_ref) = @_;
        my $f = $parent->Frame(-bg => $bg_panel)->pack(-fill => 'x', -pady => 4);
        $f->Label(-text => $label, -bg => $bg_panel, -fg => $fg_label, -anchor => 'w', -width => 22)
          ->pack(-side => 'left');

        my %style_btns;
        my $update = sub {
            for my $s (@styles) {
                if ($$style_ref eq $s) {
                    $style_btns{$s}->configure(-bg => $accent, -fg => '#FFFFFF');
                } else {
                    $style_btns{$s}->configure(-bg => $bg_field, -fg => $fg);
                }
            }
        };

        for my $s (@styles) {
            $style_btns{$s} = $f->Button(
                -text => $s,
                -bg   => $bg_field, -fg => $fg, -relief => 'flat',
                -activebackground => $accent, -activeforeground => '#FFFFFF',
                -font => 'Helvetica 8',
                -padx => 6, -pady => 2,
                -command => sub { $$style_ref = $s; $update->(); },
            )->pack(-side => 'left', -padx => 2);
        }
        $update->();
        return $f;
    };

    # Copias locales para edición
    my $v_style_d = $ovl->{style_daily};
    my $v_style_w = $ovl->{style_weekly};
    my $v_style_m = $ovl->{style_monthly};

    # Separador de sección
    my $make_sep = sub {
        my ($txt) = @_;
        $content->Label(-text => $txt, -bg => $bg_panel, -fg => $fg_label,
                        -font => 'Helvetica 8', -anchor => 'w')
                ->pack(-fill => 'x', -pady => [8, 2]);
        $content->Frame(-bg => '#2D3245', -height => 1)->pack(-fill => 'x', -pady => [0, 4]);
    };

    $make_sep->('Daily H/L  (PDH / PDL)');
    $make_row->($content, 'Estilo de línea', \$v_style_d);

    $make_sep->('Weekly H/L  (PWH / PWL)');
    $make_row->($content, 'Estilo de línea', \$v_style_w);

    $make_sep->('Monthly H/L  (PMH / PML)');
    $make_row->($content, 'Estilo de línea', \$v_style_m);

    # Botones
    my $btn_frame = $top->Frame(-bg => $bg)->pack(-fill => 'x', -padx => 16, -pady => 12);

    $btn_frame->Button(
        -text => 'Cancelar', -bg => $bg_field, -fg => $fg, -relief => 'flat',
        -command => sub { $top->destroy() },
    )->pack(-side => 'left', -padx => [0, 10]);

    $btn_frame->Button(
        -text => 'Aceptar', -bg => $accent, -fg => '#FFFFFF', -relief => 'flat',
        -command => sub {
            $ovl->{style_daily}   = $v_style_d;
            $ovl->{style_weekly}  = $v_style_w;
            $ovl->{style_monthly} = $v_style_m;
            $self->request_render();
            $top->destroy();
        },
    )->pack(-side => 'right');
}

1;
