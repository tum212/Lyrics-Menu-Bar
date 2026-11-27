use std::ffi::{c_void, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::sync::{Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

type MTActuatorCreateFn = unsafe extern "C" fn(u64) -> *mut c_void;
type MTActuatorOpenFn = unsafe extern "C" fn(*mut c_void) -> i32;
type MTActuatorCloseFn = unsafe extern "C" fn(*mut c_void) -> i32;
type MTActuatorActuateFn = unsafe extern "C" fn(*mut c_void, i32, u32, f32, f32) -> i32;

pub type CHHapticFallbackFn =
    extern "C" fn(ctx: *mut c_void, delay_secs: f64, is_deep: bool, intensity: i32);

#[repr(C)]
#[derive(Default)]
struct MachTimebaseInfo {
    numer: u32,
    denom: u32,
}

extern "C" {
    fn mach_timebase_info(info: *mut MachTimebaseInfo) -> i32;
    fn mach_absolute_time() -> u64;
    fn pthread_set_qos_class_self_np(
        qos_class: libc::c_uint,
        relative_priority: libc::c_int,
    ) -> libc::c_int;

    fn IOServiceMatching(name: *const libc::c_char) -> *mut c_void;
    fn IOServiceGetMatchingServices(
        main_port: u32,
        matching: *mut c_void,
        existing: *mut u32,
    ) -> i32;
    fn IOIteratorNext(iterator: u32) -> u32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IORegistryEntryCreateCFProperty(
        entry: u32,
        key: *const c_void,
        allocator: *const c_void,
        options: u32,
    ) -> *const c_void;

    fn CFStringCreateWithCString(
        alloc: *const c_void,
        c_str: *const libc::c_char,
        encoding: u32,
    ) -> *const c_void;
    fn CFGetTypeID(cf: *const c_void) -> libc::c_ulong;
    fn CFNumberGetTypeID() -> libc::c_ulong;
    fn CFNumberGetValue(
        number: *const c_void,
        the_type: libc::c_long,
        value_ptr: *mut c_void,
    ) -> bool;
    fn CFRelease(cf: *const c_void);
}

const K_CF_STRING_ENCODING_UTF8: u32 = 0x0800_0100;
const K_CF_NUMBER_SINT64_TYPE: libc::c_long = 4;
const QOS_CLASS_USER_INTERACTIVE: libc::c_uint = 0x21;

struct HapticMsg {
    deep_bass: f32,
    std_bass: f32,
    intensity: i32,
    buffer_host_time: u64,
    buffer_frame_count: usize,
    sample_rate: f64,
}

struct MTHandle {
    framework_handle: *mut c_void,
    actuator: *mut c_void,
    actuate_fn: MTActuatorActuateFn,
    close_fn: Option<MTActuatorCloseFn>,
}

unsafe impl Send for MTHandle {}
unsafe impl Sync for MTHandle {}

impl Drop for MTHandle {
    fn drop(&mut self) {
        unsafe {
            if !self.actuator.is_null() {
                if let Some(close) = self.close_fn {
                    let _ = close(self.actuator);
                }
                CFRelease(self.actuator.cast::<c_void>());
                self.actuator = ptr::null_mut();
            }
            if !self.framework_handle.is_null() {
                libc::dlclose(self.framework_handle);
                self.framework_handle = ptr::null_mut();
            }
        }
    }
}

#[derive(Clone, Copy)]
struct FallbackCallback {
    func: CHHapticFallbackFn,
    ctx: usize,
}

pub struct OnsetDetector {
    prev_deep: f32,
    prev_std: f32,
    bass_peak: f32,
    last_fire_wall: f64,
}

impl OnsetDetector {
    pub fn new() -> Self {
        Self {
            prev_deep: 0.0,
            prev_std: 0.0,
            bass_peak: 0.0001,
            last_fire_wall: -10.0,
        }
    }

    pub fn evaluate(
        &mut self,
        deep_bass: f32,
        std_bass: f32,
        intensity: i32,
        buffer_wall_time: f64,
    ) -> Option<bool> {
        if intensity <= 0 || !deep_bass.is_finite() || !std_bass.is_finite() {
            return None;
        }
        self.bass_peak = (self.bass_peak * 0.95).max(deep_bass.max(std_bass));
        let noise_floor = self.bass_peak * 0.20;

        let deep_ratio = deep_bass / self.prev_deep.max(0.00001);
        let std_ratio = std_bass / self.prev_std.max(0.00001);
        self.prev_deep = deep_bass;
        self.prev_std = std_bass;

        let threshold = match intensity {
            3 => 1.70,
            2 => 1.45,
            _ => 1.25,
        };
        let is_deep_hit = deep_ratio > threshold && deep_bass > noise_floor;
        let is_std_hit = std_ratio > threshold && std_bass > noise_floor;
        if !is_deep_hit && !is_std_hit {
            return None;
        }

        let min_gap = match intensity {
            3 => 0.16,
            2 => 0.13,
            _ => 0.10,
        };
        if buffer_wall_time - self.last_fire_wall < min_gap {
            return None;
        }
        self.last_fire_wall = buffer_wall_time;
        Some(is_deep_hit)
    }
}

pub fn resolve_actuator_type(override_val: i32, is_deep: bool) -> i32 {
    if override_val > 0 {
        override_val
    } else if is_deep {
        6
    } else {
        4
    }
}

enum WorkerCmd {
    Frame(HapticMsg),
    TestType(i32),
    Shutdown,
}

pub struct HapticEngine {
    tx: Mutex<Option<SyncSender<WorkerCmd>>>,
    actuator_type_override: Arc<AtomicI32>,
    latency_offset_bits: Arc<AtomicU64>,
    fallback: Arc<Mutex<Option<FallbackCallback>>>,
    shutdown: Arc<AtomicBool>,
    wake_pair: Arc<(Mutex<bool>, Condvar)>,
    worker: Mutex<Option<JoinHandle<()>>>,
    mt_available: AtomicBool,
}

#[inline]
fn mach_ticks_to_ns(ticks: u64, numer: u64, denom: u64) -> i128 {
    ((ticks as u128) * (numer as u128) / (denom.max(1) as u128)) as i128
}

impl HapticEngine {
    pub fn new() -> Self {
        let mut tb = MachTimebaseInfo::default();
        unsafe {
            mach_timebase_info(&mut tb);
        }
        let numer = tb.numer.max(1) as u64;
        let denom = tb.denom.max(1) as u64;

        let actuator_override = Arc::new(AtomicI32::new(0));
        let latency_bits = Arc::new(AtomicU64::new(0.0_f64.to_bits()));
        let fallback = Arc::new(Mutex::new(None::<FallbackCallback>));
        let shutdown = Arc::new(AtomicBool::new(false));
        let wake_pair = Arc::new((Mutex::new(false), Condvar::new()));

        let mt = unsafe { init_multitouch_actuator() };
        let mt_available = AtomicBool::new(mt.is_some());

        let (tx, rx) = mpsc::sync_channel::<WorkerCmd>(16);

        let override_clone = actuator_override.clone();
        let latency_clone = latency_bits.clone();
        let fallback_clone = fallback.clone();
        let shutdown_clone = shutdown.clone();
        let wake_clone = wake_pair.clone();

        let handle = thread::Builder::new()
            .name("lyrics-haptics".into())
            .spawn(move || {
                unsafe {
                    let _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
                }
                let mut detector = OnsetDetector::new();

                while let Ok(cmd) = rx.recv() {
                    if shutdown_clone.load(Ordering::Acquire) {
                        break;
                    }
                    match cmd {
                        WorkerCmd::Shutdown => break,
                        WorkerCmd::TestType(t) => {
                            if let Some(ref handle) = mt {
                                unsafe {
                                    let _ = (handle.actuate_fn)(handle.actuator, t, 0, 1.0, 0.0);
                                }
                            } else {
                                let cb = *fallback_clone.lock().unwrap_or_else(|e| e.into_inner());
                                if let Some(fb) = cb {
                                    (fb.func)(fb.ctx as *mut c_void, 0.0, t == 6, 3);
                                }
                            }
                        }
                        WorkerCmd::Frame(msg) => {
                            let host_ticks = if msg.buffer_host_time != 0 {
                                msg.buffer_host_time
                            } else {
                                unsafe { mach_absolute_time() }
                            };
                            let buf_ns = mach_ticks_to_ns(host_ticks, numer, denom);
                            let buf_secs = (buf_ns as f64) * 1e-9;

                            if let Some(is_deep) = detector.evaluate(
                                msg.deep_bass,
                                msg.std_bass,
                                msg.intensity,
                                buf_secs,
                            ) {
                                let onset_offset = ((msg.buffer_frame_count / 2) as f64)
                                    / msg.sample_rate.max(8000.0);
                                let base_lead = if mt.is_some() { 0.005 } else { 0.003 };
                                let lat = f64::from_bits(latency_clone.load(Ordering::Relaxed));
                                let offset_ns = ((onset_offset - (base_lead + lat)) * 1e9) as i128;
                                let fire_ns = buf_ns + offset_ns;
                                let now_ns = mach_ticks_to_ns(
                                    unsafe { mach_absolute_time() },
                                    numer,
                                    denom,
                                );
                                let delta = ((fire_ns - now_ns) as f64) * 1e-9;

                                // Drop severely stale frames (>50ms late) so bursts don't fire out of sync
                                if delta < -0.05 {
                                    continue;
                                }

                                if delta <= 0.001 {
                                    fire_actuator(
                                        mt.as_ref(),
                                        &fallback_clone,
                                        override_clone.load(Ordering::Relaxed),
                                        is_deep,
                                        msg.intensity,
                                    );
                                } else if delta < 0.15 {
                                    if mt.is_none() {
                                        let cb = *fallback_clone
                                            .lock()
                                            .unwrap_or_else(|e| e.into_inner());
                                        if let Some(fb) = cb {
                                            (fb.func)(
                                                fb.ctx as *mut c_void,
                                                delta,
                                                is_deep,
                                                msg.intensity,
                                            );
                                            continue;
                                        }
                                    }
                                    // Interruptible wait via Condvar so Drop wakes immediately
                                    let (lock, cvar) = &*wake_clone;
                                    let guard = lock.lock().unwrap_or_else(|e| e.into_inner());
                                    let _ = cvar.wait_timeout(
                                        guard,
                                        Duration::from_secs_f64(delta),
                                    );
                                    if shutdown_clone.load(Ordering::Acquire) {
                                        break;
                                    }
                                    fire_actuator(
                                        mt.as_ref(),
                                        &fallback_clone,
                                        override_clone.load(Ordering::Relaxed),
                                        is_deep,
                                        msg.intensity,
                                    );
                                }
                            }
                        }
                    }
                }
            })
            .ok();

        Self {
            tx: Mutex::new(Some(tx)),
            actuator_type_override: actuator_override,
            latency_offset_bits: latency_bits,
            fallback,
            shutdown,
            wake_pair,
            worker: Mutex::new(handle),
            mt_available,
        }
    }

    pub fn has_multitouch_actuator(&self) -> bool {
        self.mt_available.load(Ordering::Acquire)
    }

    pub fn set_actuator_type(&self, actuator_type: i32) {
        self.actuator_type_override
            .store(actuator_type, Ordering::Release);
    }

    pub fn set_latency_offset(&self, offset_secs: f64) {
        if offset_secs.is_finite() {
            self.latency_offset_bits
                .store(offset_secs.to_bits(), Ordering::Release);
        }
    }

    /// Synchronous, non-lossy fallback callback update (prevents UAF on teardown).
    pub fn set_fallback_callback(&self, func: Option<CHHapticFallbackFn>, ctx: *mut c_void) {
        let cb = func.map(|f| FallbackCallback {
            func: f,
            ctx: ctx as usize,
        });
        let mut guard = self.fallback.lock().unwrap_or_else(|e| e.into_inner());
        *guard = cb;
    }

    /// Real-time audio thread entry point — never blocks, never allocates.
    pub fn on_audio_frame(
        &self,
        deep_bass: f32,
        std_bass: f32,
        intensity: i32,
        buffer_host_time: u64,
        buffer_frame_count: usize,
        sample_rate: f32,
    ) {
        if intensity <= 0 || self.shutdown.load(Ordering::Relaxed) {
            return;
        }
        if let Ok(guard) = self.tx.try_lock() {
            if let Some(ref sender) = *guard {
                let _ = sender.try_send(WorkerCmd::Frame(HapticMsg {
                    deep_bass,
                    std_bass,
                    intensity,
                    buffer_host_time,
                    buffer_frame_count,
                    sample_rate: sample_rate as f64,
                }));
            }
        }
    }

    pub fn test_actuator_type(&self, actuator_type: i32) {
        if let Ok(guard) = self.tx.lock() {
            if let Some(ref sender) = *guard {
                let _ = sender.try_send(WorkerCmd::TestType(actuator_type));
            }
        }
    }
}

impl Drop for HapticEngine {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
        {
            let mut fb = self.fallback.lock().unwrap_or_else(|e| e.into_inner());
            *fb = None;
        }
        {
            let (lock, cvar) = &*self.wake_pair;
            let mut flag = lock.lock().unwrap_or_else(|e| e.into_inner());
            *flag = true;
            cvar.notify_all();
        }
        {
            let mut tx_guard = self.tx.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(sender) = tx_guard.take() {
                let _ = sender.try_send(WorkerCmd::Shutdown);
                drop(sender);
            }
        }
        if let Ok(mut w) = self.worker.lock() {
            if let Some(handle) = w.take() {
                let _ = handle.join();
            }
        }
    }
}

fn fire_actuator(
    mt: Option<&MTHandle>,
    fallback: &Arc<Mutex<Option<FallbackCallback>>>,
    override_type: i32,
    is_deep: bool,
    intensity: i32,
) {
    if let Some(handle) = mt {
        let t = resolve_actuator_type(override_type, is_deep);
        let amp = match intensity {
            3 => 1.0_f32,
            2 => 0.75,
            _ => 0.50,
        };
        unsafe {
            let _ = (handle.actuate_fn)(handle.actuator, t, 0, amp, 0.0);
        }
    } else {
        let cb = *fallback.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(fb) = cb {
            (fb.func)(fb.ctx as *mut c_void, 0.0, is_deep, intensity);
        }
    }
}

unsafe fn find_multitouch_id() -> Option<u64> {
    let number_type_id = CFNumberGetTypeID();
    for name in [
        "AppleMultitouchDevice",
        "AppleMultitouchTrackpadHIDEventDriver",
    ] {
        let Ok(c_name) = CString::new(name) else {
            continue;
        };
        let matching = IOServiceMatching(c_name.as_ptr());
        if matching.is_null() {
            continue;
        }
        let mut iter: u32 = 0;
        if IOServiceGetMatchingServices(0, matching, &mut iter) != 0 {
            continue;
        }
        loop {
            let device = IOIteratorNext(iter);
            if device == 0 {
                break;
            }
            for prop in ["Multitouch ID", "mt-device-id"] {
                let Ok(c_prop) = CString::new(prop) else {
                    continue;
                };
                let cf_key = CFStringCreateWithCString(
                    ptr::null(),
                    c_prop.as_ptr(),
                    K_CF_STRING_ENCODING_UTF8,
                );
                if cf_key.is_null() {
                    continue;
                }
                let val_ref = IORegistryEntryCreateCFProperty(device, cf_key, ptr::null(), 0);
                CFRelease(cf_key);
                if !val_ref.is_null() {
                    let mut out: i64 = 0;
                    let is_num = CFGetTypeID(val_ref) == number_type_id;
                    let ok = is_num
                        && CFNumberGetValue(
                            val_ref,
                            K_CF_NUMBER_SINT64_TYPE,
                            (&mut out as *mut i64).cast::<c_void>(),
                        );
                    CFRelease(val_ref);
                    if ok && out != 0 {
                        IOObjectRelease(device);
                        IOObjectRelease(iter);
                        return Some(out as u64);
                    }
                }
            }
            IOObjectRelease(device);
        }
        IOObjectRelease(iter);
    }
    None
}

unsafe fn init_multitouch_actuator() -> Option<MTHandle> {
    let fw_path = CString::new(
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport",
    )
    .ok()?;
    let handle = libc::dlopen(fw_path.as_ptr(), libc::RTLD_NOW);
    if handle.is_null() {
        return None;
    }

    let sym_create = libc::dlsym(handle, b"MTActuatorCreateFromDeviceID\0".as_ptr().cast());
    let sym_open = libc::dlsym(handle, b"MTActuatorOpen\0".as_ptr().cast());
    let sym_actuate = libc::dlsym(handle, b"MTActuatorActuate\0".as_ptr().cast());
    let sym_close = libc::dlsym(handle, b"MTActuatorClose\0".as_ptr().cast());

    if sym_create.is_null() || sym_open.is_null() || sym_actuate.is_null() {
        libc::dlclose(handle);
        return None;
    }

    let create_fn: MTActuatorCreateFn = std::mem::transmute(sym_create);
    let open_fn: MTActuatorOpenFn = std::mem::transmute(sym_open);
    let actuate_fn: MTActuatorActuateFn = std::mem::transmute(sym_actuate);
    let close_fn: Option<MTActuatorCloseFn> = if sym_close.is_null() {
        None
    } else {
        Some(std::mem::transmute(sym_close))
    };

    let Some(id) = find_multitouch_id() else {
        libc::dlclose(handle);
        return None;
    };
    let actuator = create_fn(id);
    if actuator.is_null() {
        libc::dlclose(handle);
        return None;
    }
    if open_fn(actuator) != 0 {
        CFRelease(actuator.cast::<c_void>());
        libc::dlclose(handle);
        return None;
    }

    Some(MTHandle {
        framework_handle: handle,
        actuator,
        actuate_fn,
        close_fn,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_onset_detector_selectivity_and_refractory() {
        let mut det = OnsetDetector::new();
        assert_eq!(det.evaluate(0.05, 0.05, 2, 1.0), Some(true));
        // Inside 130ms refractory -> blocked
        assert_eq!(det.evaluate(0.30, 0.10, 2, 1.05), None);
        // Drop to quiet then sharp beat after refractory -> fires
        let _ = det.evaluate(0.01, 0.01, 2, 1.15);
        assert_eq!(det.evaluate(0.08, 0.02, 2, 1.25), Some(true));
    }

    #[test]
    fn test_actuator_type_resolution() {
        assert_eq!(resolve_actuator_type(0, true), 6);
        assert_eq!(resolve_actuator_type(0, false), 4);
        assert_eq!(resolve_actuator_type(3, true), 3);
    }
}
