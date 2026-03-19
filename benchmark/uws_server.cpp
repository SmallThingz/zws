#include "App.h"

#include <charconv>
#include <cstdlib>
#include <iostream>
#include <string_view>

int main(int argc, char **argv) {
    int port = 9002;
    for (int i = 1; i < argc; i++) {
        std::string_view arg = argv[i];
        constexpr std::string_view prefix = "--port=";
        if (arg.starts_with(prefix)) {
            std::from_chars(arg.data() + prefix.size(), arg.data() + arg.size(), port);
        }
    }

    struct PerSocketData {};

    auto app = uWS::App();
    app.ws<PerSocketData>("/*", {
        .compression = uWS::DISABLED,
        .maxPayloadLength = 64 * 1024,
        .idleTimeout = 120,
        .maxBackpressure = 64 * 1024,
        .closeOnBackpressureLimit = false,
        .resetIdleTimeoutOnSend = false,
        .sendPingsAutomatically = false,
        .upgrade = nullptr,
        .open = [](auto * /*ws*/) {},
        .message = [](auto *ws, std::string_view message, uWS::OpCode opCode) {
            ws->send(message, opCode, false);
        },
        .dropped = [](auto * /*ws*/, std::string_view /*message*/, uWS::OpCode /*opCode*/) {},
        .drain = [](auto * /*ws*/) {},
        .ping = [](auto * /*ws*/, std::string_view /*message*/) {},
        .pong = [](auto * /*ws*/, std::string_view /*message*/) {},
        .close = [](auto * /*ws*/, int /*code*/, std::string_view /*message*/) {},
    });

    app.listen(port, [port](auto *listen_socket) {
        if (!listen_socket) {
            std::cerr << "failed to listen on " << port << std::endl;
            std::exit(1);
        }
    });
    app.run();
}
