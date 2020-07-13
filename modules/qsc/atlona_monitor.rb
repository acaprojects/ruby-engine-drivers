# encoding: ASCII-8BIT
# frozen_string_literal: true

module Qsc; end
class Qsc::AtlonaMonitor
  include ::Orchestrator::Constants
  include ::Orchestrator::Transcoder
  include ::Orchestrator::StateBinder

  descriptive_name 'QSC - Atlona Output Monitor'
  description 'Monitors QSC devices for changes to input streams and updates QSC controls to match'
  generic_name :AtlonaMonitor
  implements :logic

  def on_load
    # output_id => audio session stream IP
    @last_known_state = {}
    on_update
  end

  def on_update
    # { "output": {"component": "B-LC5-105-Rx", control: "PGMRx:Stream"} }
    @stream_mappings = setting(:output_stream_mappings) || {}
  end

  # Monitor changes to routes
  bind :Switcher, :routes do |routes|
    check_changes(routes)
  end

  def unroute_audio
    qsc = system[:Mixer]
    logger.debug { "unrouting all audio" }
    @last_known_state.clear
    @stream_mappings.each_value do |details|
      qsc.component_set(details[:component], {
        Name: details[:control],
        Value: ""
      })
    end
  end

  # Update QSC with any stream changes
  def check_changes(routes)
    logger.debug { "new routes: #{routes}" }

    return unless routes
    check_keys = @stream_mappings.keys.map(&:to_s) & routes.keys.map(&:to_s)
    logger.debug { "checking keys: #{check_keys}" }
    return if check_keys.empty?
    check_keys = check_keys.map { |output| [output, routes[output]] }

    # Get the decoder details
    mappings = system[:Switcher][:input_mappings]

    # Obtain the current list of multicast addresses
    output_streams = {}
    check_keys.each do |(output, input)|
      if ["0", ""].include?(input)
        output_streams[output] = ""
        next
      end

      details = mappings[input]
      if details.nil?
        logger.warn "details for input #{input.inspect} not found for output #{output.inspect} in\n#{mappings}"
        next
      end

      encoder = system[details[:encoder]]
      if encoder.nil?
        logger.warn "unable to find encoder #{details[:encoder].inspect} in system"
        next
      end

      session_index = details[:session] - 1
      mcast_address = encoder[:sessions].dig(session_index, :audio, :stream, :destination_address)
      if mcast_address.nil?
        logger.warn "unable to find mcast_address in session #{session_index} -> audio -> stream -> destination_address in \n#{encoder[:sessions]}"
        next
      end

      output_streams[output] = mcast_address
    end

    # check for any changes
    qsc = system[:Mixer]
    output_streams.each do |output_id, mcast_address|
      if @last_known_state[output_id] != mcast_address
        logger.debug { "Updating QSC stream for output #{output_id}" }
        details = @stream_mappings[output_id]
        qsc.component_set(details[:component], {
          Name: details[:control],
          Value: mcast_address
        })
      end
    end

    @last_known_state = output_streams
  end
end
