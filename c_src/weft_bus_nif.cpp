// Elixir client of 2-contract/bus's DYNAMIC command bus. Publishes a
// request-id-prefixed byte-slice command to `weft/harness/command`, subscribes
// to `weft/harness/reply`, waits until a reply carrying the matching id
// arrives (or a deadline elapses), and returns the reply body to the BEAM.
//
// This is the CLIENT half — the SERVER shape is `weft::run_command_loop` in
// `weft/loop.hpp`, used by `priv/env_bus_server.py`'s `weft_harness.bus.serve`.
// The Python side already exists; this file is what makes Elixir a peer on
// the same wire.
//
// Modeled on `2-contract/bus/proof/command_publisher.cpp` (the raw ABI
// client-side pattern) and `7-service/spot-broker/c_src/store_bus_nif.cpp`
// (the "hold iox2 handles in an Erlang resource; run on dirty IO" pattern).
//
// SPDX-License-Identifier: MIT OR Apache-2.0
#include "iox2_api.h"
#include "weft/bus.hpp"
#include "weft/command.hpp"

#include <erl_nif.h>

#include <atomic>
#include <cstring>
#include <string>
#include <vector>

namespace {

struct Client {
    iox2_node_h node = nullptr;
    iox2_port_factory_pub_sub_h cmd_service = nullptr;
    iox2_port_factory_pub_sub_h reply_service = nullptr;
    iox2_publisher_h publisher = nullptr;
    iox2_subscriber_h subscriber = nullptr;
};

ErlNifResourceType* g_client_type = nullptr;
std::atomic<std::uint64_t> g_next_request_id{1};

iox2_port_factory_pub_sub_h open_service(iox2_node_h& node, const char* name) {
    iox2_service_name_h svc = nullptr;
    if (iox2_service_name_new(nullptr, name, std::strlen(name), &svc) != IOX2_OK) {
        return nullptr;
    }
    auto builder = iox2_service_builder_pub_sub(
        iox2_node_service_builder(&node, nullptr, iox2_cast_service_name_ptr(svc)));
    if (iox2_service_builder_pub_sub_set_payload_type_details(
            &builder, iox2_type_variant_e_DYNAMIC, weft::PAYLOAD_TYPE,
            std::strlen(weft::PAYLOAD_TYPE), 1, 1) != IOX2_OK) {
        iox2_service_name_drop(svc);
        return nullptr;
    }
    iox2_port_factory_pub_sub_h service = nullptr;
    const int rc = iox2_service_builder_pub_sub_open_or_create(builder, nullptr, &service);
    iox2_service_name_drop(svc);
    return rc == IOX2_OK ? service : nullptr;
}

bool open_client(Client& c) {
    if (!weft::load_bus()) return false;
    iox2_set_log_level_from_env_or(iox2_log_level_e_ERROR);

    if (iox2_node_builder_create(iox2_node_builder_new(nullptr), nullptr,
                                 iox2_service_type_e_IPC, &c.node) != IOX2_OK) {
        return false;
    }

    c.cmd_service = open_service(c.node, weft::COMMAND_SERVICE_NAME);
    c.reply_service = open_service(c.node, weft::REPLY_SERVICE_NAME);
    if (!c.cmd_service || !c.reply_service) return false;

    auto pb = iox2_port_factory_pub_sub_publisher_builder(&c.cmd_service, nullptr);
    iox2_port_factory_publisher_builder_set_initial_max_slice_len(&pb, weft::MESSAGE_BYTES);
    if (iox2_port_factory_publisher_builder_create(pb, nullptr, &c.publisher) != IOX2_OK) {
        return false;
    }

    if (iox2_port_factory_subscriber_builder_create(
            iox2_port_factory_pub_sub_subscriber_builder(&c.reply_service, nullptr), nullptr,
            &c.subscriber) != IOX2_OK) {
        return false;
    }
    return true;
}

void destruct_client(ErlNifEnv*, void* obj) {
    Client* c = static_cast<Client*>(obj);
    if (c->publisher) iox2_publisher_drop(c->publisher);
    if (c->subscriber) iox2_subscriber_drop(c->subscriber);
    if (c->cmd_service) iox2_port_factory_pub_sub_drop(c->cmd_service);
    if (c->reply_service) iox2_port_factory_pub_sub_drop(c->reply_service);
    if (c->node) iox2_node_drop(c->node);
    new (c) Client();
}

ERL_NIF_TERM make_atom(ErlNifEnv* env, const char* a) {
    ERL_NIF_TERM t;
    if (enif_make_existing_atom(env, a, &t, ERL_NIF_LATIN1)) return t;
    return enif_make_atom(env, a);
}

ERL_NIF_TERM make_error(ErlNifEnv* env, const char* reason) {
    return enif_make_tuple2(env, make_atom(env, "error"), make_atom(env, reason));
}

ERL_NIF_TERM nif_open(ErlNifEnv* env, int, const ERL_NIF_TERM[]) {
    Client* c = static_cast<Client*>(enif_alloc_resource(g_client_type, sizeof(Client)));
    new (c) Client();
    if (!open_client(*c)) {
        destruct_client(env, c);
        enif_release_resource(c);
        return make_error(env, "bus_open_failed");
    }
    ERL_NIF_TERM ref = enif_make_resource(env, c);
    enif_release_resource(c);
    return enif_make_tuple2(env, make_atom(env, "ok"), ref);
}

ERL_NIF_TERM nif_ask(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    if (argc != 3) return enif_make_badarg(env);

    Client* c = nullptr;
    if (!enif_get_resource(env, argv[0], g_client_type, (void**)&c)) {
        return enif_make_badarg(env);
    }

    ErlNifBinary body;
    if (!enif_inspect_binary(env, argv[1], &body)) {
        return enif_make_badarg(env);
    }

    int timeout_ms = 0;
    if (!enif_get_int(env, argv[2], &timeout_ms)) return enif_make_badarg(env);

    if (body.size > weft::BODY_MAX) return make_error(env, "body_too_large");

    const std::uint64_t request_id = g_next_request_id.fetch_add(1);
    const std::size_t total = weft::HEADER_BYTES + body.size;

    // Publish command
    iox2_sample_mut_h sample = nullptr;
    if (iox2_publisher_loan_slice_uninit(&c->publisher, nullptr, &sample, total) != IOX2_OK) {
        return make_error(env, "loan_failed");
    }
    void* payload = nullptr;
    std::size_t elements = 0;
    iox2_sample_mut_payload_mut(&sample, &payload, &elements);
    weft::command_write_header(static_cast<unsigned char*>(payload), request_id);
    std::memcpy(static_cast<unsigned char*>(payload) + weft::HEADER_BYTES,
                body.data, body.size);
    if (iox2_sample_mut_send(sample, nullptr) != IOX2_OK) {
        return make_error(env, "send_failed");
    }

    // Poll for reply carrying request_id
    const int poll_ms = 10;
    const int max_polls = timeout_ms > 0 ? (timeout_ms / poll_ms + 1) : 1;

    for (int i = 0; i < max_polls; ++i) {
        iox2_sample_h reply = nullptr;
        if (iox2_subscriber_receive(&c->subscriber, nullptr, &reply) != IOX2_OK) {
            return make_error(env, "receive_failed");
        }
        if (!reply) {
            (void)iox2_node_wait(&c->node, 0, static_cast<std::uint32_t>(poll_ms * 1000 * 1000));
            continue;
        }
        const void* rp = nullptr;
        std::size_t rn = 0;
        iox2_sample_payload(&reply, &rp, &rn);
        if (rn < weft::HEADER_BYTES) {
            iox2_sample_drop(reply);
            continue;
        }
        const std::uint64_t rid =
            weft::command_read_header(static_cast<const unsigned char*>(rp));
        if (rid != request_id) {
            iox2_sample_drop(reply);
            continue;
        }
        ERL_NIF_TERM out;
        unsigned char* dst = enif_make_new_binary(env, rn - weft::HEADER_BYTES, &out);
        std::memcpy(dst, static_cast<const unsigned char*>(rp) + weft::HEADER_BYTES,
                    rn - weft::HEADER_BYTES);
        iox2_sample_drop(reply);
        return enif_make_tuple2(env, make_atom(env, "ok"), out);
    }
    return make_error(env, "timeout");
}

int load(ErlNifEnv* env, void**, ERL_NIF_TERM) {
    ErlNifResourceFlags flags =
        static_cast<ErlNifResourceFlags>(ERL_NIF_RT_CREATE | ERL_NIF_RT_TAKEOVER);
    g_client_type = enif_open_resource_type(env, nullptr, "WeftBusClient",
                                            destruct_client, flags, nullptr);
    return g_client_type ? 0 : -1;
}

ErlNifFunc nif_funcs[] = {
    {"open", 0, nif_open, 0},
    {"ask", 3, nif_ask, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

}  // namespace

ERL_NIF_INIT(Elixir.TaskweftNmmPersonas.BusNif, nif_funcs, load, nullptr, nullptr, nullptr)
