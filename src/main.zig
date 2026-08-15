const r4os = @import("r4os");

comptime {
    asm (r4os.r4dev.driverEntriesAsm("rtl8139_init", "rtl8139_shutdown"));
}

const VENDOR_REALTEK: u16 = 0x10EC;
const DEVICE_RTL8139: u16 = 0x8139;

const REG_IDR0: u16 = 0x00;
const REG_TSD0: u16 = 0x10;
const REG_TSAD0: u16 = 0x20;
const REG_RBSTART: u16 = 0x30;
const REG_COMMAND: u16 = 0x37;
const REG_CAPR: u16 = 0x38;
const REG_IMR: u16 = 0x3C;
const REG_ISR: u16 = 0x3E;
const REG_TCR: u16 = 0x40;
const REG_RCR: u16 = 0x44;
const REG_CONFIG1: u16 = 0x52;

const CMD_RESET: u8 = 0x10;
const CMD_RX_ENABLE: u8 = 0x08;
const CMD_TX_ENABLE: u8 = 0x04;
const CMD_RX_BUFFER_EMPTY: u8 = 0x01;

const ISR_ROK: u16 = 1 << 0;
const ISR_RER: u16 = 1 << 1;
const ISR_TOK: u16 = 1 << 2;
const ISR_TER: u16 = 1 << 3;
const ISR_RXOVW: u16 = 1 << 4;
const ISR_PUN: u16 = 1 << 5;
const ISR_ACTIVE: u16 = ISR_ROK | ISR_RER | ISR_TOK | ISR_TER | ISR_RXOVW | ISR_PUN;

const RCR_ACCEPT_PHYSICAL_MATCH: u32 = 1 << 1;
const RCR_ACCEPT_BROADCAST: u32 = 1 << 3;
const RCR_DMA_UNLIMITED: u32 = 7 << 8;
// 0.56.24(a): RBLEN=01 => 16 KB RX-Ring (Bits 11-12; 00=8K,01=16K,
// 10=32K,11=64K). WRAP bleibt 0 (Chip wickelt am Ringende, kein
// Ueberlauf ueber RxBufLen); der Drain wickelt bereits per % RX_BUFFER_SIZE.
const RCR_RBLEN_16K: u32 = 1 << 11;

const TSD_TOK: u32 = 1 << 15;
const TSD_TUN: u32 = 1 << 14;
// 0.56.2: Early-TX-Threshold (TSD bits [21:16], Einheit 32 Byte). Ohne
// Threshold (=0) startet der Chip TX nach nur 8 Byte im FIFO -> unter
// Buslast TX-Underruns (TUN) = die beobachteten tx_errors/write_retry.
// 0x30 (48*32 = 1536 Byte) puffert praktisch das ganze Paket vor dem
// Start und vermeidet Underruns.
const TSD_ERTXTH: u32 = 0x30 << 16;

const RX_BUFFER_SIZE: usize = 16384;
// 0.56.24(a): TX-Bereich beginnt nach dem 16-KB-RX-Ring plus 2 KB
// Reserve (RTL8139-Chip-Reserve von 16 Bytes plus Sicherheitsabstand).
// DMA_BYTES=32K deckt 18K RX-Region + 4x2K TX = 26K.
const RX_DMA_SIZE: usize = 18 * 1024;
const TX_SLOT_COUNT: usize = 4;
const TX_BUFFER_SIZE: usize = 2048;
const DMA_BYTES: u32 = 32 * 1024;
const RX_DRAIN_BUDGET: usize = 128;
// 0.56.2: Grace von 4096 auf 32 gesenkt - mit dem net-rx-Task (Poll alle
// ~10 ms) bedeutete 4096 rund 40 s Blindflug nach Boot, in denen auf
// IRQs gehofft wurde, die auf diesem Stand nicht zugestellt werden
// (Baseline-Befund hits=0).
const IRQ_FALLBACK_GRACE_POLLS: u64 = 32;
// 0.56.2: Poll-Watchdog - macht der IRQ-Pfad ueber so viele Polls keinen
// Fortschritt (irq_count unveraendert), wird defensiv per Ring-Zustand
// gedraint, statt poll() nach dem ersten IRQ dauerhaft abzuschalten
// (RX-Stall-Befund: ein einzelner spuriouser IRQ toetete den RX-Pfad).
const POLL_WATCHDOG_IDLE_POLLS: u64 = 16;

const State = struct {
    api: *const r4os.r4dev.DriverApi = undefined,
    active: bool = false,
    registered: bool = false,
    info: r4os.abi.PciDeviceInfo = .{},
    dma: r4os.abi.DmaBuffer = .{},
    io_base: u16 = 0,
    adapter_index: i32 = -1,
    mac: [6]u8 = .{0} ** 6,
    rx_head: u16 = 0,
    tx_slot: u8 = 0,
    rx_ok: u64 = 0,
    tx_ok: u64 = 0,
    rx_errors: u64 = 0,
    tx_errors: u64 = 0,
    rx_overflow: u64 = 0,
    bad_frames: u64 = 0,
    poll_count: u64 = 0,
    poll_fallbacks: u64 = 0,
    irq_registered: bool = false,
    irq_register_result: i32 = 0,
    irq_routes: [10]u8 = .{0xFF} ** 10,
    irq_route_count: usize = 0,
    irq_active_route: u8 = 0xFF,
    irq_count: u64 = 0,
    irq_handled: u64 = 0,
    // 0.56.21 (Befund 6.6 vorgezogen): IRQ-vs-Poll-Drain-Guard. Der
    // aktivierte IRQ-Pfad kann den Poll-Task mitten in drainRx
    // unterbrechen - ohne Guard bewegen beide den Ring-Cursor.
    drain_busy: bool = false,
    drain_pending: bool = false,
    drain_pending_invalid: bool = false,
    drain_pending_ovw: bool = false,
    irq_deferred: u64 = 0,
    irq_unhandled: u64 = 0,
    irq_tx_ok: u64 = 0,
    irq_mode: u8 = 0,
    last_isr: u16 = 0,
    watchdog_irq_seen: u64 = 0,
    watchdog_idle_polls: u64 = 0,
    watchdog_drains: u64 = 0,
    rx_recoveries: u64 = 0,
    // 0.56.37: transmit() ist NICHT reentrant - Slot-Wahl, Puffer-Kopie
    // und TSAD/TSD-Writes muessen atomar zusammenbleiben. Seit der
    // 4-KB-IPC-Segmentierung feuert der proaktive net-rx-Retransmit
    // (0.56.25) real und laeuft PARALLEL zum Service-Task-Write; ohne
    // Guard desynct die Slot-Rotation gegen den QEMU-currTxDesc und
    // der TX-Ring klemmt permanent (tx_busy-Sturm, Frames erreichen
    // den Draht nie - Repro/Bisect 2026-07-05). Konkurrierende Sender
    // bekommen busy(1); alle Aufrufer pacen darauf bereits.
    tx_lock: bool = false,
    // 0.56.7 (TX v2): Slot gilt als in-flight, bis TOK/TUN gesehen wurde.
    tx_pending: [TX_SLOT_COUNT]bool = .{false} ** TX_SLOT_COUNT,
    // 0.56.40: tx_pending_since traegt jetzt ctx.tickCount()-Ticks
    // (ECHTZEIT), nicht mehr poll_count - der Poll-Zaehler war keine
    // stabile Zeitbasis (0.56.29-Befund: Rate skaliert mit Last und
    // Wait-Slices, bei der 1000-Hz-Probe kollabierten TX-Slots nach
    // ~300 ms). Schwelle: tx_stuck_ticks = 3 s echt, bei init aus
    // timerFrequency() berechnet.
    tx_pending_since: [TX_SLOT_COUNT]u64 = .{0} ** TX_SLOT_COUNT,
    tx_stuck_ticks: u64 = 300,
    tx_busy: u64 = 0,
    tx_stuck_reclaims: u64 = 0,
    rx_scratch: [1536]u8 = .{0} ** 1536,
};

var state: State = .{};
var backend: r4os.abi.NetBackend = .{};
var poll_active: bool = false;

export fn rtl8139_init(api: *const r4os.r4dev.DriverApi) callconv(.c) i32 {
    state = .{ .api = api };
    poll_active = false;
    var ctx = context();
    ctx.logInfo("RTL8139.R4D init");

    const info = findDevice(&ctx) orelse {
        ctx.logWarn("RTL8139.R4D device not found");
        return -1;
    };
    state.info = info;

    const bar0 = ctx.pciReadBar(info, 0);
    if ((bar0 & 1) == 0) {
        ctx.logError("RTL8139.R4D missing IO BAR0");
        return -2;
    }
    state.io_base = @truncate(bar0 & 0xFFFC);
    if (state.io_base == 0) {
        ctx.logError("RTL8139.R4D IO base is zero");
        return -3;
    }

    if (ctx.pciEnableBusMaster(info, r4os.abi.pci_enable_io_space) != 0) {
        ctx.logError("RTL8139.R4D bus master enable failed");
        return -4;
    }

    wakeDevice(&ctx);
    if (!softReset(&ctx)) {
        ctx.logWarn("RTL8139.R4D reset timeout");
    }
    readMac(&ctx);

    if (ctx.allocDmaRegion(DMA_BYTES, 4096, &state.dma) != 0 or state.dma.phys_addr == 0 or state.dma.virt_addr == 0) {
        ctx.logError("RTL8139.R4D dma allocation failed");
        return -5;
    }
    prepareTraffic(&ctx);

    backend = .{};
    backend.version = r4os.abi.net_backend_version;
    backend.size = @sizeOf(r4os.abi.NetBackend);
    backend.flags = r4os.abi.net_backend_flag_link_up | r4os.abi.net_backend_flag_broadcast | r4os.abi.net_backend_flag_trusted;
    backend.mtu = 1500;
    backend.bus_kind = info.bus_kind;
    backend.bus = info.bus;
    backend.device = info.device;
    backend.function = info.function;
    backend.vendor_id = info.vendor_id;
    backend.device_id = info.device_id;
    backend.mac = state.mac;
    backend.context = &state;
    backend.transmit = transmit;
    backend.poll = poll;
    backend.shutdown = backendShutdown;
    backend.status = status;

    const adapter = ctx.registerNetBackend("rtl8139", &backend);
    if (adapter < 0) {
        ctx.logError("RTL8139.R4D register_net_backend failed");
        shutdownHardware(&ctx);
        return -6;
    }

    state.adapter_index = adapter;
    state.registered = true;
    // 0.56.40: Dead-Slot-Schwelle in echten Ticks (3 s).
    state.tx_stuck_ticks = 3 * @as(u64, ctx.timerFrequency());
    if (state.tx_stuck_ticks == 0) state.tx_stuck_ticks = 300;
    setupInterrupt(&ctx);
    state.active = true;
    ctx.logInfo("RTL8139.R4D registered");
    return 0;
}

export fn rtl8139_shutdown() callconv(.c) i32 {
    var ctx = context();
    ctx.logInfo("RTL8139.R4D shutdown");
    shutdownHardware(&ctx);
    return 0;
}

fn findDevice(ctx: *const r4os.r4dev.DriverContext) ?r4os.abi.PciDeviceInfo {
    var index: u32 = 0;
    const total = ctx.pciDeviceCount();
    while (index < total) : (index += 1) {
        var info: r4os.abi.PciDeviceInfo = .{};
        if (ctx.pciDeviceAt(index, &info) != 0) continue;
        if (info.vendor_id == VENDOR_REALTEK and info.device_id == DEVICE_RTL8139) return info;
    }
    index = 0;
    while (ctx.pciFindByClass(0x02, 0x00, index, &state.info) >= 0) : (index += 1) {
        if (state.info.vendor_id == VENDOR_REALTEK and state.info.device_id == DEVICE_RTL8139) return state.info;
    }
    return null;
}

// 0.56.7 (TX v2): Warten VOR der Wiederverwendung statt NACH dem Start.
// Geschichte der drei gescheiterten Varianten (alle am 2026-07-03 belegt):
//   (1) Original: nach dem TSD-Write bis 100000 Port-Reads auf TOK spinnen
//       -> unter SLIRP-Stau 100-500 ms VM-Exit-Sturm PRO Send, synchron im
//       Aufruferkontext -> 40-s-SSH-Blackouts (write_retry=468).
//   (2) Async mit Force-Reclaim: Busy-Streak reclaimte in-flight Slots ->
//       TX-Puffer wurde ueberschrieben, waehrend QEMU ihn noch las ->
//       Frame-Korruption, FTP reihenweise rot (Gate 1/6).
//   (3) Spin-Deckel 2000: Timeout feuerte staendig, und der Timeout-Pfad
//       rotierte weiter -> dieselbe Wiederverwendung in-flight Puffer wie
//       (2), nur ueber den Umweg (Gate 1/6).
// Lehre: Der einzige unsichere Zustand ist die WIEDERVERWENDUNG eines
// in-flight Slots. Also: beim Senden nur pruefen, ob der aelteste Slot
// frei ist (TOK/TUN abrechnen; QEMU sendet praktisch synchron -> im
// Normalfall genau EIN Status-Read); ist er noch in Flight, kurz bounded
// nachfassen und sonst busy melden OHNE Rotation und OHNE Wiederverwendung
// - TCP paced per Retransmit. Kein Force-Reclaim: verlorene TOKs gibt es
// nur nach Chip-Reset, und dort (prepareTraffic/recoverRxOverflow) wird
// die pending-Buchhaltung explizit geleert.
fn txSlotFree(s: *State, ctx: *const r4os.r4dev.DriverContext, slot: usize) bool {
    if (!s.tx_pending[slot]) return true;
    const status_word = ctx.portInl(s.io_base + REG_TSD0 + @as(u16, @intCast(slot * 4)));
    if ((status_word & TSD_TOK) != 0) {
        s.tx_ok += 1;
        s.tx_pending[slot] = false;
        return true;
    }
    if ((status_word & TSD_TUN) != 0) {
        s.tx_errors += 1;
        s.tx_pending[slot] = false;
        return true;
    }
    // Sicherheitsnetz gegen echt verlorene TOKs (nur nach Chip-Anomalien):
    // ein Deskriptor, der nach ~300 Polls (~3 s; legitime QEMU-Flugzeit
    // liegt bei Millisekunden) weder TOK noch TUN hat, ist tot. 0.56.11:
    // Schwelle von 2000 (~20 s) gesenkt - sie lag LAENGER als das
    // 15-s-Write-Budget des SSHD, ein Lost-TOK-Stall liess damit ganze
    // Sessions kollabieren (write_retry=251, worker max_ticks=1627),
    // bevor der Slot sich selbst heilte. Nicht tiefer setzen, sonst
    // droht wieder die Wiederverwendung live gelesener Puffer.
    // 0.56.40 (ex 0.56.29b): Schwelle auf ECHTZEIT umgestellt -
    // 3 s via tickCount/timerFrequency statt 300 Polls.
    if (ctx.tickCount() -% s.tx_pending_since[slot] > s.tx_stuck_ticks) {
        s.tx_errors += 1;
        s.tx_stuck_reclaims += 1;
        s.tx_pending[slot] = false;
        return true;
    }
    return false;
}

fn transmit(raw_context: ?*anyopaque, frame: [*]const u8, len: u32) callconv(.c) i32 {
    const s = stateFrom(raw_context) orelse return 5;
    if (!s.active or s.io_base == 0 or s.dma.virt_addr == 0) return 5;
    if (len == 0 or len > TX_BUFFER_SIZE) return 2;
    if (@atomicRmw(bool, &s.tx_lock, .Xchg, true, .acq_rel)) {
        s.tx_busy += 1;
        return 1;
    }
    defer @atomicStore(bool, &s.tx_lock, false, .release);
    var ctx = context();
    const slot: usize = s.tx_slot % TX_SLOT_COUNT;

    if (!txSlotFree(s, &ctx, slot)) {
        // Aeltester Slot noch in Flight: kurz nachfassen (deckt den
        // QEMU-Normalfall "TOK kommt gleich"), sonst busy an den
        // Aufrufer. Slot-Zeiger bleibt stehen - NIE einen in-flight
        // Puffer ueberschreiben.
        var spin: usize = 0;
        var free = false;
        while (spin < 400) : (spin += 1) {
            if (txSlotFree(s, &ctx, slot)) {
                free = true;
                break;
            }
        }
        if (!free) {
            s.tx_busy += 1;
            return 1;
        }
    }

    const tx = txSlotBytes(s, slot);
    var i: usize = 0;
    while (i < len) : (i += 1) tx[i] = frame[i];
    ctx.portOutl(s.io_base + REG_TSAD0 + @as(u16, @intCast(slot * 4)), @truncate(s.dma.phys_addr + RX_DMA_SIZE + slot * TX_BUFFER_SIZE));
    ctx.portOutl(s.io_base + REG_TSD0 + @as(u16, @intCast(slot * 4)), TSD_ERTXTH | len);
    s.tx_pending[slot] = true;
    s.tx_pending_since[slot] = ctx.tickCount();
    s.tx_slot = @intCast((slot + 1) % TX_SLOT_COUNT);
    return 0;
}

fn poll(raw_context: ?*anyopaque) callconv(.c) void {
    const s = stateFrom(raw_context) orelse return;
    if (!s.active or s.io_base == 0 or s.dma.virt_addr == 0) return;
    if (poll_active) return;
    poll_active = true;
    defer poll_active = false;
    var ctx = context();
    s.poll_count += 1;
    var force_drain = false;
    if (s.irq_registered and s.irq_count > 0) {
        // Watchdog statt Dauer-Abschaltung: Solange IRQs Fortschritt
        // machen, halten sich Polls zurueck; stagniert irq_count, wird
        // nach POLL_WATCHDOG_IDLE_POLLS defensiv gedraint.
        if (s.irq_count != s.watchdog_irq_seen) {
            s.watchdog_irq_seen = s.irq_count;
            s.watchdog_idle_polls = 0;
            return;
        }
        s.watchdog_idle_polls += 1;
        if (s.watchdog_idle_polls < POLL_WATCHDOG_IDLE_POLLS) return;
        s.watchdog_idle_polls = 0;
        s.watchdog_drains += 1;
        force_drain = true;
    } else if (s.irq_registered) {
        s.poll_fallbacks += 1;
        if (s.poll_fallbacks < IRQ_FALLBACK_GRACE_POLLS) return;
        force_drain = true;
    } else if (s.irq_mode == 2) {
        s.poll_fallbacks += 1;
    }
    const isr = ctx.portInw(s.io_base + REG_ISR);
    // Drain nach Ring-Zustand (CMD_RX_BUFFER_EMPTY), nicht nur nach
    // ISR-Bits: gelatchte/geackte ISR-Zustaende duerfen keine Frames
    // im Ring liegen lassen.
    if (s.irq_mode == 2 or force_drain) {
        s.drain_busy = true;
        drainRx(s, (isr & (ISR_RER | ISR_RXOVW | ISR_PUN)) != 0);
        s.drain_busy = false;
        flushDeferredDrain(s);
    }
    serviceIsr(s, isr, false);
}

fn backendShutdown(raw_context: ?*anyopaque) callconv(.c) i32 {
    _ = raw_context;
    var ctx = context();
    shutdownHardware(&ctx);
    return 0;
}

fn status(raw_context: ?*anyopaque, out: *r4os.abi.NetBackendStatus) callconv(.c) i32 {
    const s = stateFrom(raw_context) orelse return -1;
    out.* = .{
        .link_up = if (s.active) 1 else 0,
        .rx_packets = s.rx_ok,
        .tx_packets = s.tx_ok,
        .drops = s.bad_frames,
        .errors = s.rx_errors + s.tx_errors + s.rx_overflow,
        .irq_line = irqDisplayLine(s),
        .irq_pin = s.info.interrupt_pin,
        .irq_registered = if (s.irq_registered) 1 else 0,
        .irq_mode = s.irq_mode,
        .irq_count = s.irq_count,
        .irq_handled = s.irq_handled,
        .poll_count = s.poll_count,
        .poll_fallbacks = s.poll_fallbacks,
        .last_isr = s.last_isr,
        // reserved traegt die RX-Overflow-Recoveries (0.56.2-Diagnose);
        // das ABI-Feld war ungenutzt.
        .reserved = @truncate(s.rx_recoveries),
        // 0.56.7: Fehleraufschluesselung (der Sammelzaehler `errors`
        // verdeckte die Klasse - RX-Fehler vs. TX-Underrun vs. Overflow).
        .rx_errors = s.rx_errors,
        .tx_errors = s.tx_errors,
        .rx_overflows = s.rx_overflow,
        .rx_recoveries = s.rx_recoveries,
    };
    return 0;
}

fn shutdownHardware(ctx: *const r4os.r4dev.DriverContext) void {
    if (state.io_base != 0) {
        ctx.portOutw(state.io_base + REG_IMR, 0);
        ctx.portOutw(state.io_base + REG_ISR, 0xFFFF);
        ctx.portOutb(state.io_base + REG_COMMAND, 0);
    }
    if (state.irq_registered) {
        var index: usize = 0;
        while (index < state.irq_route_count) : (index += 1) {
            _ = ctx.irqUnregister(state.irq_routes[index], irqHandler, @intFromPtr(&state));
        }
        state.irq_registered = false;
        state.irq_route_count = 0;
    }
    if (state.dma.phys_addr != 0) ctx.freeDmaRegion(&state.dma);
    state.active = false;
    state.registered = false;
}

// 0.56.7 (TX v2): Nach einem echten Chip-Setup sind in-flight Sends
// sicher verworfen - nur HIER darf die pending-Buchhaltung geleert
// werden (recoverRxOverflow laesst TX enabled, dort NICHT leeren).
fn clearTxPending(s: *State) void {
    var slot: usize = 0;
    while (slot < TX_SLOT_COUNT) : (slot += 1) {
        s.tx_pending[slot] = false;
        s.tx_pending_since[slot] = 0;
    }
}

fn prepareTraffic(ctx: *const r4os.r4dev.DriverContext) void {
    ctx.portOutw(state.io_base + REG_IMR, 0);
    ctx.portOutw(state.io_base + REG_ISR, 0xFFFF);
    ctx.portOutl(state.io_base + REG_RBSTART, @truncate(state.dma.phys_addr));
    var slot: usize = 0;
    while (slot < TX_SLOT_COUNT) : (slot += 1) {
        ctx.portOutl(state.io_base + REG_TSAD0 + @as(u16, @intCast(slot * 4)), @truncate(state.dma.phys_addr + RX_DMA_SIZE + slot * TX_BUFFER_SIZE));
    }
    ctx.portOutl(state.io_base + REG_RCR, RCR_ACCEPT_PHYSICAL_MATCH | RCR_ACCEPT_BROADCAST | RCR_DMA_UNLIMITED | RCR_RBLEN_16K);
    ctx.portOutl(state.io_base + REG_TCR, 0);
    state.rx_head = 0;
    state.tx_slot = 0;
    clearTxPending(&state);
    ctx.portOutw(state.io_base + REG_CAPR, 0xFFF0);
    ctx.portOutb(state.io_base + REG_COMMAND, CMD_RX_ENABLE | CMD_TX_ENABLE);
}

fn setupInterrupt(ctx: *const r4os.r4dev.DriverContext) void {
    state.irq_mode = 0;
    state.irq_registered = false;
    state.irq_register_result = 0;
    state.irq_route_count = 0;
    state.irq_active_route = 0xFF;
    if (irqDisabled(ctx)) {
        state.irq_mode = 2;
        state.irq_register_result = -4;
        ctx.portOutw(state.io_base + REG_IMR, 0);
        ctx.logWarn("RTL8139.R4D irq disabled by option, polling fallback");
        return;
    }
    if (state.info.interrupt_pin == 0) {
        state.irq_mode = 2;
        state.irq_register_result = -1;
        ctx.portOutw(state.io_base + REG_IMR, 0);
        ctx.logWarn("RTL8139.R4D irq route missing, polling fallback");
        return;
    }

    if (state.info.interrupt_line != 0xFF) {
        _ = registerIrqRoute(ctx, state.info.interrupt_line);
    }
    // 0.56.21: GSI 16-23 IMMER mitregistrieren, nicht nur bei PCIe-
    // Enumeration. Auf Q35 landen PCI-INTx-Leitungen auf GSI 16-23
    // (PIRQ-Routing); die interrupt_line (z.B. 10) ist nur der Legacy-
    // PIC-Wert aus dem BIOS. Nur-line-Registrierung ergab
    // "registered=yes hits=0" (Befund 6.1/0.56.2-Diagnose). Der Handler
    // prueft das ISR-Register und meldet fremde IRQs unhandled, die
    // Routen sind shared+level-low - Mitregistrieren ist gefahrlos.
    {
        var gsi: u8 = 16;
        while (gsi < 24) : (gsi += 1) {
            _ = registerIrqRoute(ctx, gsi);
        }
    }

    if (state.irq_route_count > 0) {
        state.irq_registered = true;
        state.irq_mode = 1;
        ctx.portOutw(state.io_base + REG_IMR, ISR_ACTIVE);
        ctx.logInfo("RTL8139.R4D irq registered");
    } else {
        state.irq_mode = 2;
        ctx.portOutw(state.io_base + REG_IMR, 0);
        ctx.logWarn("RTL8139.R4D irq register failed, polling fallback");
    }
}

fn registerIrqRoute(ctx: *const r4os.r4dev.DriverContext, route: u8) bool {
    if (route >= 32 or state.irq_route_count >= state.irq_routes.len) return false;
    var index: usize = 0;
    while (index < state.irq_route_count) : (index += 1) {
        if (state.irq_routes[index] == route) return true;
    }
    const result = ctx.irqRegister(route, irqHandler, @intFromPtr(&state), r4os.abi.irq_flag_shared | r4os.abi.irq_flag_level_low);
    state.irq_register_result = result;
    if (result != 0) return false;
    state.irq_routes[state.irq_route_count] = route;
    state.irq_route_count += 1;
    return true;
}

fn irqDisabled(ctx: *const r4os.r4dev.DriverContext) bool {
    const value = ctx.getOption("RTL8139", "irq");
    return zEqIgnoreCase(value, "off") or zEqIgnoreCase(value, "disabled") or zEqIgnoreCase(value, "0");
}

fn zEqIgnoreCase(value: [*:0]const u8, text: []const u8) bool {
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const c = value[index];
        if (c == 0 or upper(c) != upper(text[index])) return false;
    }
    return value[text.len] == 0;
}

fn upper(c: u8) u8 {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    return c;
}

fn irqHandler(irq: u8, raw_context: usize) callconv(.c) u32 {
    const s: *State = @ptrFromInt(raw_context);
    if (!s.active or s.io_base == 0 or s.dma.virt_addr == 0) return 0;
    var ctx = context();
    const isr = ctx.portInw(s.io_base + REG_ISR);
    if ((isr & ISR_ACTIVE) == 0) {
        s.irq_unhandled += 1;
        s.last_isr = isr;
        return 0;
    }
    s.irq_count += 1;
    s.irq_active_route = irq;
    serviceIsr(s, isr, true);
    s.irq_handled += 1;
    return r4os.abi.irq_result_handled;
}

fn irqDisplayLine(s: *State) u8 {
    if (s.irq_active_route != 0xFF) return s.irq_active_route;
    if (s.irq_route_count > 0) return s.irq_routes[0];
    return s.info.interrupt_line;
}

fn serviceIsr(s: *State, raw_isr: u16, from_irq: bool) void {
    var ctx = context();
    const isr = raw_isr & ISR_ACTIVE;
    s.last_isr = raw_isr;
    if (isr == 0) return;
    if ((isr & ISR_TOK) != 0 and from_irq) s.irq_tx_ok += 1;
    if ((isr & ISR_RER) != 0) s.rx_errors += 1;
    if ((isr & ISR_TER) != 0) s.tx_errors += 1;
    if ((isr & ISR_PUN) != 0) s.rx_errors += 1;
    if (from_irq and s.drain_busy) {
        // Poll-Kontext steht mitten im Ring-Drain: nur quittieren und
        // Nacharbeit anmelden statt den Cursor parallel zu bewegen.
        s.irq_deferred += 1;
        s.drain_pending = true;
        if ((isr & (ISR_RER | ISR_RXOVW | ISR_PUN)) != 0) s.drain_pending_invalid = true;
        if ((isr & ISR_RXOVW) != 0) s.drain_pending_ovw = true;
        ctx.portOutw(s.io_base + REG_ISR, isr);
        return;
    }
    s.drain_busy = true;
    drainRx(s, (isr & (ISR_RER | ISR_RXOVW | ISR_PUN)) != 0);
    s.drain_busy = false;
    ctx.portOutw(s.io_base + REG_ISR, isr);
    if ((isr & ISR_RXOVW) != 0) {
        // 0.56.2: RX-Overflow stoppt den Receiver des RTL8139 dauerhaft -
        // nur zaehlen reicht nicht (Root-Cause des Gate-Determinismus-
        // Problems: nic_rx fror nach dem Boot-Burst ein). Erst retten,
        // was im Ring liegt (drainRx oben), dann Receiver neu aufsetzen;
        // verlorene Frames holt TCP per Retransmit zurueck.
        s.rx_overflow += 1;
        recoverRxOverflow(s);
    }
    flushDeferredDrain(s);
}

// Vom IRQ angemeldete Nacharbeit im Task-Kontext abarbeiten; die
// while-Schleife faengt IRQs, die WAEHREND des Nachlaufs deferren.
fn flushDeferredDrain(s: *State) void {
    while (s.drain_pending) {
        s.drain_pending = false;
        const invalid = s.drain_pending_invalid;
        s.drain_pending_invalid = false;
        const ovw = s.drain_pending_ovw;
        s.drain_pending_ovw = false;
        s.drain_busy = true;
        drainRx(s, invalid);
        s.drain_busy = false;
        if (ovw) {
            s.rx_overflow += 1;
            recoverRxOverflow(s);
        }
    }
}

fn recoverRxOverflow(s: *State) void {
    var ctx = context();
    ctx.portOutb(s.io_base + REG_COMMAND, CMD_TX_ENABLE);
    s.rx_head = 0;
    ctx.portOutl(s.io_base + REG_RBSTART, @truncate(s.dma.phys_addr));
    ctx.portOutl(s.io_base + REG_RCR, RCR_ACCEPT_PHYSICAL_MATCH | RCR_ACCEPT_BROADCAST | RCR_DMA_UNLIMITED | RCR_RBLEN_16K);
    ctx.portOutw(s.io_base + REG_CAPR, 0xFFF0);
    ctx.portOutb(s.io_base + REG_COMMAND, CMD_RX_ENABLE | CMD_TX_ENABLE);
    ctx.portOutw(s.io_base + REG_ISR, ISR_RXOVW | ISR_ROK);
    s.rx_recoveries += 1;
}

fn drainRx(s: *State, count_invalid: bool) void {
    var ctx = context();
    var guard: usize = 0;
    const rx = rxBytes(s);
    while ((ctx.portInb(s.io_base + REG_COMMAND) & CMD_RX_BUFFER_EMPTY) == 0 and guard < RX_DRAIN_BUDGET) : (guard += 1) {
        const head = @as(usize, s.rx_head) % RX_BUFFER_SIZE;
        const frame_status = readRxLe16(rx, head);
        const len = readRxLe16(rx, head + 2);
        if (frame_status == 0 or len == 0) break;
        if ((frame_status & 1) == 0 or len < 4 or len > 1536 + 4) {
            if (count_invalid) s.bad_frames += 1;
            break;
        }
        const frame_len: usize = @intCast(len - 4);
        const frame_start = (head + 4) % RX_BUFFER_SIZE;
        if (frame_start + frame_len <= RX_BUFFER_SIZE) {
            const frame = rx[frame_start .. frame_start + frame_len];
            if (ctx.netReceiveFrame(s.adapter_index, frame) == 0) {
                s.rx_ok += 1;
            } else {
                s.bad_frames += 1;
            }
        } else if (frame_len <= s.rx_scratch.len) {
            copyRxSpan(rx, frame_start, s.rx_scratch[0..frame_len]);
            if (ctx.netReceiveFrame(s.adapter_index, s.rx_scratch[0..frame_len]) == 0) {
                s.rx_ok += 1;
            } else {
                s.bad_frames += 1;
            }
        } else {
            s.bad_frames += 1;
        }
        advanceRx(s, 4 + @as(usize, len));
    }
}

fn advanceRx(s: *State, bytes: usize) void {
    var ctx = context();
    var next = (@as(usize, s.rx_head) + bytes + 3) & ~@as(usize, 3);
    if (next >= RX_BUFFER_SIZE) next -= RX_BUFFER_SIZE;
    s.rx_head = @intCast(next);
    const capr = @as(u16, @truncate(next)) -% 16;
    ctx.portOutw(s.io_base + REG_CAPR, capr);
}

fn wakeDevice(ctx: *const r4os.r4dev.DriverContext) void {
    ctx.portOutb(state.io_base + REG_CONFIG1, 0);
}

fn softReset(ctx: *const r4os.r4dev.DriverContext) bool {
    ctx.portOutb(state.io_base + REG_COMMAND, CMD_RESET);
    var spin: usize = 0;
    while (spin < 100000) : (spin += 1) {
        if ((ctx.portInb(state.io_base + REG_COMMAND) & CMD_RESET) == 0) return true;
    }
    return false;
}

fn readMac(ctx: *const r4os.r4dev.DriverContext) void {
    var i: u16 = 0;
    while (i < 6) : (i += 1) state.mac[i] = ctx.portInb(state.io_base + REG_IDR0 + i);
}

fn stateFrom(raw_context: ?*anyopaque) ?*State {
    const ptr = raw_context orelse return null;
    return @ptrCast(@alignCast(ptr));
}

fn context() r4os.r4dev.DriverContext {
    return r4os.r4dev.DriverContext.init(state.api);
}

fn rxBytes(s: *State) []u8 {
    const data: [*]u8 = @ptrFromInt(s.dma.virt_addr);
    return data[0..RX_BUFFER_SIZE];
}

fn txSlotBytes(s: *State, slot: usize) []u8 {
    const data: [*]u8 = @ptrFromInt(s.dma.virt_addr + RX_DMA_SIZE + slot * TX_BUFFER_SIZE);
    return data[0..TX_BUFFER_SIZE];
}

fn readRxLe16(rx: []const u8, offset: usize) u16 {
    const first = rx[offset % RX_BUFFER_SIZE];
    const second = rx[(offset + 1) % RX_BUFFER_SIZE];
    return @as(u16, first) | (@as(u16, second) << 8);
}

fn copyRxSpan(rx: []const u8, start: usize, out: []u8) void {
    var copied: usize = 0;
    while (copied < out.len) {
        const src = (start + copied) % RX_BUFFER_SIZE;
        const run = @min(out.len - copied, RX_BUFFER_SIZE - src);
        @memcpy(out[copied .. copied + run], rx[src .. src + run]);
        copied += run;
    }
}
