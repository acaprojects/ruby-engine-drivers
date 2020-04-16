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

  # Update QSC with any stream changes
  def check_changes(routes)
    return unless routes
    check_keys = @stream_mappings.keys.map(&:to_s) & routes.keys.map(&:to_s)
    return if check_keys.empty?

    # Get the decoder details
    mappings = system[:Switcher][:output_mappings]

    # Obtain the current list of multicast addresses
    output_streams = {}
    check_keys.each do |output|
      details = mappings[output]

      decoder = system[details[:decoder]]
      if decoder.nil?
        logger.warn "unable to find decoder #{details[:decoder].inspect} in system"
        next
      end
      output_index = details[:output] - 1

      input_name = decoder[:outputs].dig(output_index, :video, :input)
      if input_name.nil?
        logger.warn "unable to find name of output #{output_index.inspect} -> video -> input in \n#{decoder[:outputs]}"
        next
      end
      mcast_address = decoder[:ip_inputs].dig(input_name, :multicast, :address)
      if mcast_address.nil?
        logger.warn "unable to find mcast_address of decoder input #{input_name.inspect} -> multicast -> address in \n#{decoder[:ip_inputs]}"
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
