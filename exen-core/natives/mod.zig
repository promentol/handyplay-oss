//! Native dispatch by `funcs_407AA2[]` index.
//!
//! Each ExEn class with native methods has a file under `natives/<package>/<Class>.zig`
//! exposing `pub fn handle(vm, idx, frame) Error!void`. The folder structure
//! mirrors the Java package name exactly:
//!   - exen.Graphics      → natives/exen/Graphics.zig
//!   - exen.util.Debug    → natives/exen/util/Debug.zig
//!   - java.lang.String   → natives/java/lang/String.zig
//!   - vm.sys.Runtime     → natives/vm/sys/Runtime.zig
//!   - catalog.Catalog    → natives/catalog/Catalog.zig
//!
//! Single-responsibility: each file owns exactly one class's native
//! handlers, period. No cross-class dispatch logic, no shared switch.
//!
//! Wiring: `core.boot()` initialises the VM with a no-op default
//! dispatcher; the frontend calls `core.setNativeDispatcher(&dispatch)`
//! before any gamelet bytecode runs so all NATIVE method invocations
//! reach this module.

const core = @import("core");
const interp = core.interp;

// Per-class handler imports — kept alphabetical within each package.
const exen_AnimBitmap     = @import("exen/AnimBitmap.zig");
const exen_AnimFlash      = @import("exen/AnimFlash.zig");
const exen_DialogBox      = @import("exen/DialogBox.zig");
const exen_Displayable    = @import("exen/Displayable.zig");
const exen_FX             = @import("exen/FX.zig");
const exen_Gamelet        = @import("exen/Gamelet.zig");
const exen_Graphics       = @import("exen/Graphics.zig");
const exen_Image          = @import("exen/Image.zig");
const exen_List           = @import("exen/List.zig");
const exen_Math           = @import("exen/Math.zig");
const exen_Matrix3D       = @import("exen/Matrix3D.zig");
const exen_PlayField      = @import("exen/PlayField.zig");
const exen_RayCast        = @import("exen/RayCast.zig");
const exen_Resource       = @import("exen/Resource.zig");
const exen_Sms            = @import("exen/Sms.zig");
const exen_Vector3D       = @import("exen/Vector3D.zig");
const exen_util_Debug     = @import("exen/util/Debug.zig");
const java_lang_Class     = @import("java/lang/Class.zig");
const java_lang_Object    = @import("java/lang/Object.zig");
const java_lang_String    = @import("java/lang/String.zig");
const java_lang_StringBuffer = @import("java/lang/StringBuffer.zig");
const vm_sys_Runtime      = @import("vm/sys/Runtime.zig");
const catalog_Catalog     = @import("catalog/Catalog.zig");
const catalog_GameProperty = @import("catalog/GameProperty.zig");

/// Dispatch a native call by its `funcs_407AA2[]` index. The owning
/// class is determined by the contiguous index range each class
/// occupies in that table (see `docs/native_index_map.md`).
pub fn dispatch(vm: *interp.Vm, idx: u32, frame: *interp.Frame) interp.Error!void {
    return switch (idx) {
        0...14   => exen_Graphics.handle(vm, idx, frame),
        15...29  => exen_Image.handle(vm, idx, frame),
        30...42  => exen_Resource.handle(vm, idx, frame),
        43...45  => exen_AnimBitmap.handle(vm, idx, frame),
        46...53  => exen_PlayField.handle(vm, idx, frame),
        54...64  => exen_AnimFlash.handle(vm, idx, frame),
        65...66  => exen_Displayable.handle(vm, idx, frame),
        67...88  => exen_Gamelet.handle(vm, idx, frame),
        89...100 => exen_Sms.handle(vm, idx, frame),
        101...102 => exen_DialogBox.handle(vm, idx, frame),
        103...108 => exen_FX.handle(vm, idx, frame),
        109      => exen_List.handle(vm, idx, frame),
        110...122 => exen_Math.handle(vm, idx, frame),
        123...128 => exen_Matrix3D.handle(vm, idx, frame),
        129...136 => exen_Vector3D.handle(vm, idx, frame),
        137...146 => exen_RayCast.handle(vm, idx, frame),
        147...150 => exen_util_Debug.handle(vm, idx, frame),
        151...154 => java_lang_Object.handle(vm, idx, frame),
        155...157 => java_lang_Class.handle(vm, idx, frame),
        158...165 => java_lang_String.handle(vm, idx, frame),
        166...174 => java_lang_StringBuffer.handle(vm, idx, frame),
        175...177 => vm_sys_Runtime.handle(vm, idx, frame),
        178...183 => catalog_Catalog.handle(vm, idx, frame),
        184      => catalog_GameProperty.handle(vm, idx, frame),
        else     => interp.Error.UnknownNative,
    };
}
