# frozen_string_literal: true
# encoding: ASCII-8BIT

module Aca; end
class Aca::Ping
    include ::Orchestrator::Constants

    # Discovery Information
    udp_port 9
    descriptive_name 'Ping Device (ICMP)'
    generic_name :Ping

    default_settings({
        ping_every: '2m',
        ping_count: 2
    })

    def on_load
        on_update
    end

    def on_update
        @ping_count = setting(:ping_count) || 2
        schedule.clear
        schedule.every(setting(:ping_every) || '2m') { ping_device }
    end

    def ping_device
        ping = ::UV::Ping.new(remote_address, count: @ping_count)
        ping.ping
        set_connected_state(ping.pingable)
        logger.debug { {
            host: ping.ip,
            pingable: ping.pingable,
            warning: ping.warning,
            exception: ping.exception
        }.inspect }
        ping.pingable
    end
end
