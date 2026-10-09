#include "AppImageUpdater.hpp"

#ifdef __linux__

#include "GUI_App.hpp"
#include "GUI_Init.hpp"
#include "I18N.hpp"
#include "MsgDialog.hpp"
#include "slic3r/Utils/Http.hpp"

#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <thread>
#include <vector>

#include <unistd.h>
#include <sys/stat.h>

#include <boost/algorithm/string/case_conv.hpp>
#include <boost/filesystem.hpp>
#include <boost/log/trivial.hpp>
#include <openssl/evp.h>

#include <wx/progdlg.h>
#include <wx/utils.h>

namespace Slic3r { namespace GUI {

namespace fs = boost::filesystem;

namespace {

std::string sha256_hex(const std::string& data)
{
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int  len = 0;
    if (EVP_Digest(data.data(), data.size(), digest, &len, EVP_sha256(), nullptr) != 1)
        return {};
    std::string hex;
    hex.reserve(len * 2);
    char buf[3];
    for (unsigned int i = 0; i < len; ++i) {
        std::snprintf(buf, sizeof(buf), "%02x", digest[i]);
        hex += buf;
    }
    return hex;
}

// Starts the (replaced) AppImage once this process has exited, with this process's arguments
// (--datadir, files to open) and the AppImage runtime's environment of the old mount stripped,
// like desktop_open_datadir_folder() does.
void relaunch_after_exit(const std::string& appimage)
{
    std::vector<std::string> args = {"/bin/sh", "-c",
                                     "pid=$1; shift; while kill -0 \"$pid\" 2>/dev/null; do sleep 0.3; done; exec \"$@\"",
                                     "sh", std::to_string(::getpid()), appimage};
    // wxTheApp->argv holds only the program name (GUI_Run passes wxEntry just argv[0]).
    if (const GUI_InitParams* params = wxGetApp().init_params)
        for (int i = 1; i < params->argc; ++i)
            args.emplace_back(params->argv[i]);
    std::vector<const char*> argv;
    for (const std::string& arg : args)
        argv.push_back(arg.c_str());
    argv.push_back(nullptr);

    wxEnvVariableHashMap env_vars;
    wxGetEnvMap(&env_vars);
    for (const char* name : {"APPIMAGE", "APPDIR", "ARGV0", "OWD", "LD_LIBRARY_PATH", "LD_PRELOAD", "UNION_PRELOAD"})
        env_vars.erase(name);
    wxExecuteEnv exec_env;
    exec_env.env = std::move(env_vars);
    wxString owd;
    if (wxGetEnv("OWD", &owd))
        exec_env.cwd = owd;

    if (::wxExecute(const_cast<char**>(argv.data()), wxEXEC_ASYNC | wxEXEC_MAKE_GROUP_LEADER, nullptr, &exec_env) <= 0)
        BOOST_LOG_TRIVIAL(error) << "AppImage update: failed to schedule restart of " << appimage;
}

} // namespace

bool appimage_can_self_update()
{
    const char* appimage_env = std::getenv("APPIMAGE");
    if (appimage_env == nullptr)
        return false;
    const fs::path            target(appimage_env);
    boost::system::error_code ec;
    return fs::is_regular_file(target, ec) && ::access(target.c_str(), W_OK) == 0 && ::access(target.parent_path().c_str(), W_OK) == 0;
}

AppImageUpdateResult appimage_self_update(wxWindow* parent, const std::string& url, const std::string& sha256, size_t size, const std::string& version)
{
    if (url.empty())
        return AppImageUpdateResult::NotApplicable;
    if (!appimage_can_self_update()) {
        BOOST_LOG_TRIVIAL(info) << "AppImage update: not running from a replaceable AppImage, falling back to browser download";
        return AppImageUpdateResult::NotApplicable;
    }
    const fs::path            target(std::getenv("APPIMAGE"));
    boost::system::error_code ec;
    if (sha256.empty()) {
        // Never install an unverified binary.
        BOOST_LOG_TRIVIAL(warning) << "AppImage update: manifest has no file_sha256, falling back to browser download";
        return AppImageUpdateResult::NotApplicable;
    }

    struct State
    {
        std::atomic<bool>   done{false};
        std::atomic<bool>   cancel{false};
        std::atomic<size_t> now{0};
        std::atomic<size_t> total{0};
        std::mutex          mutex;
        std::string         body;
        std::string         error;
    };
    auto state = std::make_shared<State>();

    std::thread worker([url, size, state] {
        Http::get(url)
            .timeout_connect(15)
            .size_limit(size) // 0: Http default cap (DEFAULT_SIZE_LIMIT, 1 GiB)
            .on_progress([state](Http::Progress progress, bool& cancel) {
                state->now   = progress.dlnow;
                state->total = progress.dltotal;
                cancel       = state->cancel;
            })
            .on_complete([state](std::string body, unsigned) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->body = std::move(body);
            })
            .on_error([state](std::string, std::string error, unsigned status) {
                std::lock_guard<std::mutex> lock(state->mutex);
                state->error = error.empty() ? "HTTP " + std::to_string(status) : error;
            })
            .perform_sync();
        state->done = true;
    });

    {
        wxProgressDialog progress(_L("Update"), wxString::Format(_L("Downloading Snapmaker Orca %s..."), wxString::FromUTF8(version)),
                                  1000, parent, wxPD_APP_MODAL | wxPD_AUTO_HIDE | wxPD_CAN_ABORT | wxPD_ELAPSED_TIME);
        while (!state->done) {
            const size_t total = state->total;
            const int    value = total > 0 ? int(std::min<size_t>(999, state->now * 1000 / total)) : 0;
            if (!progress.Update(value))
                state->cancel = true;
            wxMilliSleep(100);
        }
    }
    worker.join();

    if (state->cancel)
        return AppImageUpdateResult::Cancelled;
    if (!state->error.empty()) {
        MessageDialog(parent, wxString::Format(_L("Downloading the update failed: %s"), wxString::FromUTF8(state->error)), _L("Update"),
                      wxICON_ERROR | wxOK)
            .ShowModal();
        return AppImageUpdateResult::Failed;
    }
    if (sha256_hex(state->body) != boost::algorithm::to_lower_copy(sha256)) {
        BOOST_LOG_TRIVIAL(error) << "AppImage update: checksum mismatch for " << url;
        MessageDialog(parent, _L("The downloaded update is damaged (checksum mismatch). Nothing was changed."), _L("Update"),
                      wxICON_ERROR | wxOK)
            .ShowModal();
        return AppImageUpdateResult::Failed;
    }

    // Write next to the target and rename over it: the running AppImage stays mounted from the old
    // inode, and a crash mid-write never leaves a truncated AppImage behind. The pid keeps two
    // instances updating at once from writing into the same staging file.
    const fs::path staged = target.string() + ".update-" + std::to_string(::getpid());
    {
        std::ofstream out(staged.string(), std::ios::binary | std::ios::trunc);
        out.write(state->body.data(), std::streamsize(state->body.size()));
        out.close(); // flush now: a failing flush in the destructor would go unnoticed
        if (out.fail()) {
            fs::remove(staged, ec);
            MessageDialog(parent, wxString::Format(_L("Could not write %s."), wxString::FromUTF8(staged.string())), _L("Update"),
                          wxICON_ERROR | wxOK)
                .ShowModal();
            return AppImageUpdateResult::Failed;
        }
    }
    struct stat st{};
    ::chmod(staged.c_str(), ::stat(target.c_str(), &st) == 0 ? (st.st_mode & 07777) : 0755);
    fs::rename(staged, target, ec);
    if (ec) {
        fs::remove(staged, ec);
        MessageDialog(parent, wxString::Format(_L("Could not replace %s."), wxString::FromUTF8(target.string())), _L("Update"),
                      wxICON_ERROR | wxOK)
            .ShowModal();
        return AppImageUpdateResult::Failed;
    }
    BOOST_LOG_TRIVIAL(info) << "AppImage update: installed " << version << " to " << target;

    MessageDialog restart(parent,
                          wxString::Format(_L("Snapmaker Orca %s is installed. Restart now to use it?"), wxString::FromUTF8(version)),
                          _L("Update"), wxICON_QUESTION | wxYES_NO);
    if (restart.ShowModal() != wxID_YES)
        return AppImageUpdateResult::Installed;
    relaunch_after_exit(target.string());
    return AppImageUpdateResult::RestartRequested;
}

}} // namespace Slic3r::GUI

#else

namespace Slic3r { namespace GUI {
bool appimage_can_self_update() { return false; }
AppImageUpdateResult appimage_self_update(wxWindow*, const std::string&, const std::string&, size_t, const std::string&)
{
    return AppImageUpdateResult::NotApplicable;
}
}} // namespace Slic3r::GUI

#endif
