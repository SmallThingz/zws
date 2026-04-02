#include "App.h"

#include <charconv>
#include <cstdlib>
#include <iostream>
#include <string>
#include <string_view>
#include <unordered_map>

enum class Mode {
    Sync,
    Async,
};

int main(int argc, char **argv) {
    int port = 9002;
    int idleTimeoutSeconds = 120;
    bool deadlineEnabled = false;
    Mode mode = Mode::Sync;
    for (int i = 1; i < argc; i++) {
        std::string_view arg = argv[i];
        constexpr std::string_view prefix = "--port=";
        constexpr std::string_view deadlinePrefix = "--deadline-ms=";
        constexpr std::string_view modePrefix = "--mode=";
        if (arg.starts_with(prefix)) {
            std::from_chars(arg.data() + prefix.size(), arg.data() + arg.size(), port);
        } else if (arg.starts_with(deadlinePrefix)) {
            int deadlineMs = 0;
            std::from_chars(arg.data() + deadlinePrefix.size(), arg.data() + arg.size(), deadlineMs);
            if (deadlineMs > 0) {
                deadlineEnabled = true;
                idleTimeoutSeconds = (deadlineMs + 999) / 1000;
                if (idleTimeoutSeconds < 8) {
                    idleTimeoutSeconds = 8;
                }
            }
        } else if (arg.starts_with(modePrefix)) {
            std::string_view modeArg = arg.substr(modePrefix.size());
            if (modeArg == "sync") {
                mode = Mode::Sync;
            } else if (modeArg == "async") {
                mode = Mode::Async;
            } else {
                std::cerr << "unknown mode: " << modeArg << std::endl;
                return 1;
            }
        }
    }

    struct PerSocketData {
        std::uint64_t id = 0;
    };

    using Socket = uWS::WebSocket<false, true, PerSocketData>;

    std::unordered_map<std::uint64_t, Socket *> sockets;
    std::uint64_t nextSocketId = 1;

    auto app = uWS::App();
    app.ws<PerSocketData>("/*", {
        .compression = uWS::DISABLED,
        .maxPayloadLength = 64 * 1024,
        .idleTimeout = static_cast<unsigned short>(idleTimeoutSeconds),
        .maxBackpressure = 64 * 1024,
        .closeOnBackpressureLimit = false,
        .resetIdleTimeoutOnSend = deadlineEnabled,
        .sendPingsAutomatically = false,
        .upgrade = nullptr,
        .open = [&sockets, &nextSocketId](auto *ws) {
            auto *psd = ws->getUserData();
            psd->id = nextSocketId++;
            sockets.emplace(psd->id, ws);
        },
        .message = [&sockets, mode](auto *ws, std::string_view message, uWS::OpCode opCode) {
            if (mode == Mode::Sync) {
                ws->send(message, opCode, false);
                return;
            }

            const std::uint64_t id = ws->getUserData()->id;
            std::string payload(message);
            uWS::Loop::get()->defer([&sockets, id, opCode, payload = std::move(payload)]() mutable {
                auto it = sockets.find(id);
                if (it == sockets.end()) {
                    return;
                }
                it->second->send(std::string_view(payload), opCode, false);
            });
        },
        .dropped = [](auto * /*ws*/, std::string_view /*message*/, uWS::OpCode /*opCode*/) {},
        .drain = [](auto * /*ws*/) {},
        .ping = [](auto * /*ws*/, std::string_view /*message*/) {},
        .pong = [](auto * /*ws*/, std::string_view /*message*/) {},
        .close = [&sockets](auto *ws, int /*code*/, std::string_view /*message*/) {
            sockets.erase(ws->getUserData()->id);
        },
    });

    app.listen(port, [port](auto *listen_socket) {
        if (!listen_socket) {
            std::cerr << "failed to listen on " << port << std::endl;
            std::exit(1);
        }
    });
    app.run();
}
