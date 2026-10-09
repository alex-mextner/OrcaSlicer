#include "LanAutoConnect.hpp"

#include "GUI_App.hpp"
#include "SSWCP.hpp"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "slic3r/Utils/MQTT.hpp"
#include "slic3r/Utils/MoonRaker.hpp"
#include "slic3r/Utils/PrintHost.hpp"
#include "slic3r/Utils/SnapLogClient.hpp"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>

#include <boost/log/trivial.hpp>
#include <nlohmann/json.hpp>
#include <openssl/evp.h>

namespace Slic3r { namespace GUI {

namespace {

using nlohmann::json;

// LAN pairing endpoint of Snapmaker printers, as used by the Device page: plain MQTT on 1884, topics
// prefixed with the access code. The Device page (resources/web/flutter_web, LAN endpoint builder)
// uses "12345678" whenever no access code was entered, and app_config does not keep one per device,
// so a code-protected printer is not reconnected here (no reply; the user connects on the Device page).
constexpr int         kPairingPort    = 1884;
constexpr const char* kPairingPrefix  = "12345678";
constexpr auto        kPairingTimeout = std::chrono::seconds(10);

// Asks the printer for the TLS credentials of an already authorized client id.
// Returns the RPC "result" object, or nullopt when the printer is unreachable or does not answer.
std::optional<json> confirm_lan_status(const std::string& ip, const std::string& client_id)
{
    const auto request_id = std::chrono::duration_cast<std::chrono::milliseconds>(
                                std::chrono::system_clock::now().time_since_epoch()).count();

    struct Reply
    {
        std::mutex              mutex;
        std::condition_variable cv;
        std::optional<json>     result;
    };
    // Shared with the MQTT callback thread, which may still run after this function returns.
    auto reply = std::make_shared<Reply>();

    // shared_ptr-owned: MqttClient::connection_lost() calls shared_from_this().
    auto probe = std::make_shared<MqttClient>("mqtt://" + ip + ":" + std::to_string(kPairingPort),
                                              "orca-auto-" + std::to_string(request_id), "", "", true);
    std::string msg;
    if (!probe->Connect(msg)) {
        BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] printer " << ip << " not reachable: " << msg;
        return std::nullopt;
    }
    probe->SetMessageCallback([reply, request_id](const std::string&, const std::string& payload) {
        json message = json::parse(payload, nullptr, false);
        auto id      = message.is_object() ? message.find("id") : message.end();
        if (!message.is_object() || id == message.end() || !id->is_number_integer() || id->get<int64_t>() != request_id)
            return;
        std::lock_guard<std::mutex> lock(reply->mutex);
        reply->result = message.contains("result") ? message["result"] : json::object();
        reply->cv.notify_all();
    });

    std::optional<json> result;
    const json request = {{"jsonrpc", "2.0"},
                          {"method", "server.client_manager.confirm_lan_status"},
                          {"params", {{"clientid", client_id}}},
                          {"id", request_id}};
    if (probe->Subscribe(std::string(kPairingPrefix) + "/config/response", 1, msg) &&
        probe->Publish(std::string(kPairingPrefix) + "/config/request", request.dump(), 1, msg)) {
        std::unique_lock<std::mutex> lock(reply->mutex);
        reply->cv.wait_for(lock, kPairingTimeout, [&] { return reply->result.has_value(); });
        result = reply->result;
    }
    probe->Disconnect(msg);
    return result;
}

std::string str_or(const json& object, const char* key, const std::string& fallback)
{
    auto it = object.find(key);
    return it != object.end() && it->is_string() && !it->get<std::string>().empty() ? it->get<std::string>() : fallback;
}

void connect_in_background_impl(DeviceInfo device, DynamicPrintConfig config, std::string pinned_ca)
{
    const std::optional<json> creds = confirm_lan_status(device.ip, device.clientId);
    if (!creds || creds->value("state", "") != "success") {
        // "unauthorized": the printer forgot this client; the user has to add it again on the Device page.
        BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] " << device.sn << " not reconnected, state: "
                                << (creds ? creds->value("state", "") : std::string("no reply"));
        return;
    }

    // The reply comes over plain MQTT on the LAN: only accept credentials for the expected printer
    // and client, signed by the CA seen on earlier connections to it.
    if (str_or(*creds, "sn", "") != device.sn || str_or(*creds, "clientid", "") != device.clientId) {
        BOOST_LOG_TRIVIAL(warning) << "[LanAutoConnect] " << device.sn << ": reply is for another printer or client, ignored";
        return;
    }
    const std::string ca = str_or(*creds, "ca", "");
    if (ca.empty() || str_or(*creds, "cert", "").empty() || str_or(*creds, "key", "").empty()) {
        // Moonraker_Mqtt::connect() would fall back to an interactive pairing request.
        BOOST_LOG_TRIVIAL(warning) << "[LanAutoConnect] " << device.sn << ": printer returned no TLS credentials";
        return;
    }
    if (lan_ca_fingerprint(ca) != pinned_ca) {
        BOOST_LOG_TRIVIAL(warning) << "[LanAutoConnect] " << device.sn << ": CA differs from the pinned one, not connecting";
        return;
    }

    const int port = creds->value("port", device.port > 0 ? device.port : 8883);
    json      params;
    params["ca"]       = ca;
    params["cert"]     = str_or(*creds, "cert", "");
    params["key"]      = str_or(*creds, "key", "");
    params["port"]     = port;
    params["clientId"] = device.clientId;
    params["sn"]       = device.sn;

    if (!GUI_App::m_app_alive)
        return;
    std::shared_ptr<PrintHost> current;
    wxGetApp().get_connect_host(current);
    if (current)
        return; // the user connected a printer in the meantime

    config.set("print_host", device.ip + ":" + std::to_string(port));
    std::shared_ptr<PrintHost> base(PrintHost::get_print_host(&config));
    auto                       host = std::dynamic_pointer_cast<Moonraker_Mqtt>(base);
    wxString                   msg;
    if (!host || !host->connect(msg, params)) {
        BOOST_LOG_TRIVIAL(warning) << "[LanAutoConnect] " << device.sn << ": TLS connect failed: " << msg.ToUTF8().data();
        return;
    }
    // The link can drop before the UI thread publishes the host. Whoever moves `state` off Pending
    // first wins: a loss before publishing just abandons the attempt (nothing to tear down, no
    // "disconnected" dialog); the first loss after it runs the normal connection-lost handling,
    // like for a Device-page connection. Later calls (the teardown's own disconnect) do nothing.
    enum : int { Pending, Published, Lost };
    auto state = std::make_shared<std::atomic<int>>(Pending);
    host->set_connection_lost([state]() {
        int s = state->load();
        while (s != Lost && !state->compare_exchange_weak(s, Lost)) {} // s: the state it left
        if (s == Published)
            sm_lan_on_connection_lost();
    });
    BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] connected to " << device.sn << " at " << device.ip;

    if (!GUI_App::m_app_alive)
        return;
    wxGetApp().CallAfter([base, host, config, device, state, sn = params["sn"].get<std::string>(),
                          client_id = params["clientId"].get<std::string>()]() {
        if (!GUI_App::m_app_alive)
            return;
        std::shared_ptr<PrintHost> current;
        wxGetApp().get_connect_host(current);
        if (current) {
            // The user connected a printer from the Device page while this was in flight; keep theirs.
            BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] another printer got connected meanwhile, dropping auto-connect";
            return;
        }
        int expected = Pending;
        if (!state->compare_exchange_strong(expected, Published)) {
            BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] connection dropped before it was published";
            return;
        }
        wxGetApp().set_connect_host(base);
        wxGetApp().set_host_config(config);
        // Same reset as a connect from the Device page (sw_mqtt_set_engine).
        wxGetApp().app_config->clear_filament_extruder_map();
        ::Slic3r::SnapLog::v1::SnapLogClient::instance().set_print_sn(sn);
        ::Slic3r::SnapLog::v1::SnapLogClient::instance().set_connect_clientid(client_id);
        json connect_params;
        connect_params["sn"] = sn;
        sm_lan_on_connected(host, connect_params, device.ip, "lan", device.id, device.userid, /*reload_device_view=*/false);
    });
}

void connect_in_background(DeviceInfo device, DynamicPrintConfig config, std::string pinned_ca)
{
    // Detached thread: an exception escaping it (e.g. a reply field of an unexpected JSON type)
    // would terminate the app.
    try {
        connect_in_background_impl(std::move(device), std::move(config), std::move(pinned_ca));
    } catch (const std::exception& e) {
        BOOST_LOG_TRIVIAL(warning) << "[LanAutoConnect] aborted: " << e.what();
    }
}

} // namespace

void start_lan_auto_connect()
{
    GUI_App&   app    = wxGetApp();
    AppConfig* config = app.app_config;
    if (config == nullptr || !config->get_bool("auto_connect_last_printer"))
        return;

    std::shared_ptr<PrintHost> current;
    app.get_connect_host(current);
    if (current)
        return;

    // The last printer connected over LAN and its CA, both recorded by sm_lan_on_connected. Without a
    // pin (no connection since this was introduced, or the device was deleted) nothing is trusted
    // yet: the user connects once on the Device page.
    const std::string last      = config->get("last_connected_device");
    std::string       pinned_ca = config->get("last_connected_ca_sha256");
    if (last.empty() || pinned_ca.empty())
        return;
    std::optional<DeviceInfo> target;
    for (const DeviceInfo& device : config->get_devices()) {
        if (device.link_mode == "lan" && device.dev_id == last && !device.ip.empty() && !device.clientId.empty() && !device.sn.empty()) {
            target = device;
            break;
        }
    }
    if (!target)
        return;

    DynamicPrintConfig host_config = app.preset_bundle->printers.get_edited_preset().config;
    host_config.option<ConfigOptionEnum<PrintHostType>>("host_type", true)->value = htMoonRaker_mqtt;

    BOOST_LOG_TRIVIAL(info) << "[LanAutoConnect] reconnecting to " << target->sn << " at " << target->ip;
    std::thread(connect_in_background, *target, std::move(host_config), std::move(pinned_ca)).detach();
}

std::string lan_ca_fingerprint(const std::string& ca_pem)
{
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int  len = 0;
    if (ca_pem.empty() || EVP_Digest(ca_pem.data(), ca_pem.size(), digest, &len, EVP_sha256(), nullptr) != 1)
        return {};
    static constexpr char hex[] = "0123456789abcdef";
    std::string           out;
    out.reserve(len * 2);
    for (unsigned int i = 0; i < len; ++i) {
        out += hex[digest[i] >> 4];
        out += hex[digest[i] & 0xf];
    }
    return out;
}

}} // namespace Slic3r::GUI
