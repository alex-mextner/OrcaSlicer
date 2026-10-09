#pragma once

#include <string>

namespace Slic3r { namespace GUI {

// Background reconnect to the last LAN printer at startup (app_config "auto_connect_last_printer",
// on by default). Re-fetches the TLS credentials with server.client_manager.confirm_lan_status for
// the stored client id, which the printer answers without a confirmation on its screen, then
// connects like the Device page does. Gives up silently if the printer is unreachable or no longer
// authorizes this client; never switches the main window tab. Call on the UI thread.
void start_lan_auto_connect();

// SHA-256 (hex) of a printer's CA certificate PEM, pinned per last connected printer; empty for "".
std::string lan_ca_fingerprint(const std::string& ca_pem);

}} // namespace Slic3r::GUI
