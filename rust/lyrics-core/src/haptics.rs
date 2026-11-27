use std::ffi::{c_void, CString};
use std::ptr;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::mpsc::{self, SyncSender};
use std::thread;
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
    fn pthread_set_qos_class_self_np(qos_class: libc::c_uint, relative_priority: libc::c_int) -> libc::c_int;

    fn IOServiceMatching(name: *const libc::c_char) -> *mut c_void;
    fn IOServiceGetMatchingServices(main_port: u32, matching: *mut c_void, existing: *mut u32) -> i32;
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
    fn CFNumberGetValue(number: *const c_void, the_type: libc::c_long, value_ptr: *mut c_void) -> bool;
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
            last_fire_wall: 0.0,
        }
    }

    pub fn evaluate(
        &mut self,
        deep_bass: f32,
        std_bass: f32,
        intensity: i32,
        buffer_wall_time: f64,
    ) -> Option<bool> {
        if intensity <= 0 {
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
    SetFallback(Option<FallbackCallback>),
    Shutdown,
}

pub struct HapticEngine {
    tx: SyncSender<WorkerCmd>,
    actuator_type_override: std::sync::Arc<AtomicI32>,
    latency_offset_bits: std::sync::Arc<AtomicU64>,
    mt_available: AtomicBool,
}

impl HapticEngine {
    pub fn new() -> Self {
        let mut tb = MachTimebaseInfo::default();
        unsafe {
            mach_timebase_info(&mut tb);
        }
        let numer = tb.numer.max(1) as u64;
        let denom = tb.denom.max(1) as u64;

        let actuator_override = std::sync::Arc::new(AtomicI32::new(0));
        let latency_bits = std::sync::Arc::new(AtomicU64::new(0.0_f64.to_bits()));

        let mt = unsafe { init_multitouch_actuator() };
        let mt_available = AtomicBool::new(mt.is_some());

        let (tx, rx) = mpsc::sync_channel::<WorkerCmd>(16);

        let override_clone = actuator_override.clone();
        let latency_clone = latency_bits.clone();

        let _ = thread::Builder::new()
            .name("lyrics-haptics".into())
            .spawn(move || {
                unsafe {
                    let _ = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
                }
                let mut detector = OnsetDetector::new();
                let mut fallback: Option<FallbackCallback> = None;

                while let Ok(cmd) = rx.recv() {
                    match cmd {
                        WorkerCmd::Shutdown => break,
                        WorkerCmd::SetFallback(cb) => {
                            fallback = cb;
                        }
                        WorkerCmd::TestType(t) => {
                            if let Some(ref handle) = mt {
                                unsafe {
                                    let _ = (handle.actuate_fn)(handle.actuator, t, 0, 1.0, 0.0);
                                }
                            } else if let Some(fb) = fallback {
                                (fb.func)(fb.ctx as *mut c_void, 0.0, t == 6, 3);
                            }
                        }
                        WorkerCmd::Frame(msg) => {
                            let buf_wall = (msg.buffer_host_time as f64) * (numer as f64)
                                / (denom as f64)
                                * 1e-9;
                            if let Some(is_deep) = detector.evaluate(
                                msg.deep_bass,
                                msg.std_bass,
                                msg.intensity,
                                buf_wall,
                            ) {
                                let onset_offset =
                                    ((msg.buffer_frame_count / 2) as f64) / msg.sample_rate.max(8000.0);
                                let base_lead = if mt.is_some() { 0.005 } else { 0.003 };
                                let lat = f64::from_bits(latency_clone.load(Ordering::Relaxed));
                                let fire_wall = buf_wall + onset_offset - (base_lead + lat);
                                let now_mach = (unsafe { mach_absolute_time() } as f64)
                                    * (numer as f64)
                                    / (denom as f64)
                                    * 1e-9;
                                let delta = fire_wall - now_mach;

                                if delta <= 0.001 {
                                    fire_actuator(
                                        mt.as_ref(),
                                        fallback,
                                        override_clone.load(Ordering::Relaxed),
                                        is_deep,
                                        msg.intensity,
                                    );
                                } else if delta < 0.15 {
                                    if let Some(fb) = fallback {
                                        if mt.is_none() {
                                            (fb.func)(
                                                fb.ctx as *mut c_void,
                                                delta,
                                                is_deep,
                                                msg.intensity,
                                            );
                                            continue;
                                        }
                                    }
                                    thread::sleep(Duration::from_secs_f64(delta));
                                    fire_actuator(
                                        mt.as_ref(),
                                        fallback,
                                        override_clone.load(Ordering::Relaxed),
                                        is_deep,
                                        msg.intensity,
                                    );
                                }
                            }
                        }
                    }
                }
            });

        Self {
            tx,
            actuator_type_override: actuator_override,
            latency_offset_bits: latency_bits,
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
        self.latency_offset_bits
            .store(offset_secs.to_bits(), Ordering::Release);
    }

    pub fn set_fallback_callback(&self, func: Option<CHHapticFallbackFn>, ctx: *mut c_void) {
        let cb = func.map(|f| FallbackCallback {
            func: f,
            ctx: ctx as usize,
        });
        let _ = self.tx.try_send(WorkerCmd::SetFallback(cb));
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
        if intensity <= 0 {
            return;
        }
        let _ = self.tx.try_send(WorkerCmd::Frame(HapticMsg {
            deep_bass,
            std_bass,
            intensity,
            buffer_host_time,
            buffer_frame_count,
            sample_rate: sample_rate as f64,
        }));
    }

    pub fn test_actuator_type(&self, actuator_type: i32) {
        let _ = self.tx.try_send(WorkerCmd::TestType(actuator_type));
    }
}

impl Drop for HapticEngine {
    fn drop(&mut self) {
        let _ = self.tx.try_send(WorkerCmd::Shutdown);
    }
}

fn fire_actuator(
    mt: Option<&MTHandle>,
    fallback: Option<FallbackCallback>,
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
    } else if let Some(fb) = fallback {
        (fb.func)(fb.ctx as *mut c_void, 0.0, is_deep, intensity);
    }
}

unsafe fn find_multitouch_id() -> Option<u64> {
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
                    let ok = CFNumberGetValue(
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
    let fw_path =
        CString::new("/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/Current/MultitouchSupport")
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
    if actuator.is_null() || open_fn(actuator) != 0 {
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
        // Establish baseline frame
        let _ = det.evaluate(0.1, 0.1, 2, 1.0);
        // Small steady increase (<1.45x ratio) does not fire
        assert_eq!(det.evaluate(0.12, 0.12, 2, 1.2), None);
        // Strong kick (>1.45x) triggers deep beat
        assert_eq!(det.evaluate(0.45, 0.12, 2, 1.4), Some(true));
        // Double-fire within refractory (0.13s) blocked
        assert_eq!(det.evaluate(0.95, 0.95, 2, 1.45), None);
        // Settle back to quiet baseline before next onset
        assert_eq!(det.evaluate(0.10, 0.10, 2, 1.50), None);
        // Outside refractory triggers standard beat
        assert_eq!(det.evaluate(0.10, 0.50, 2, 1.65), Some(false));
    }

    #[test]
    fn test_actuator_type_resolution() {
        assert_eq!(resolve_actuator_type(0, true), 6);
        assert_eq!(resolve_actuator_type(0, false), 4);
        assert_eq!(resolve_actuator_type(2, true), 2);
        assert_eq!(resolve_actuator_type(5, false), 5);
    }
}
