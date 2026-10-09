#pragma once

#include <string>

class wxWindow;

namespace Slic3r { namespace GUI {

// True when the app runs from an AppImage whose file and directory are writable, i.e. when
// appimage_self_update() can install in place (Linux only).
bool appimage_can_self_update();

enum class AppImageUpdateResult
{
    NotApplicable,    // not a replaceable AppImage or no checksum: let the browser download it
    Cancelled,        // the user cancelled the download; nothing was changed
    Failed,           // an error was shown to the user; nothing was changed
    Installed,        // installed; the user chose to restart later
    RestartRequested, // installed and the user chose to restart: close the main window
};

// In-place update of the running AppImage (Linux only): downloads `url` with a progress dialog,
// verifies `sha256` (hex, required), atomically replaces the AppImage and offers to restart. On
// RestartRequested the new AppImage starts once this process exits. A non-zero `size` (bytes, from
// the manifest) caps the download.
AppImageUpdateResult appimage_self_update(wxWindow* parent, const std::string& url, const std::string& sha256, size_t size, const std::string& version);

}} // namespace Slic3r::GUI
