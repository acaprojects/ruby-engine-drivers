# frozen_string_literal: true

module TvOne; end

# Documentation: https://aca.im/driver_docs/TV%20One/CORIOmaster-Commands-v1.7.0.pdf

class TvOne::CorioMaster
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    tcp_port 10001
    descriptive_name 'tvOne CORIOmaster image processor'
    generic_name :VideoWall

    tokenize wait_ready: 'Interface Ready', callback: :tokenize

    default_settings username: 'admin', password: 'adminpw'


    # ------------------------------
    # Calllbacks

    def connected
        schedule.every('60s') do
            do_poll
        end

        init_connection.then do
            query 'CORIOmax.Serial_Number',    expose_as: :serial_number
            query 'CORIOmax.Software_Version', expose_as: :firmware
        end
    end

    def disconnected
        schedule.clear
    end


    # ------------------------------
    # Main API

    def preset(id)
        set('Preset.Take', id).then do
            # The full query of window params can take up to ~15 seconds. To
            # speed things up a little for other modules that depend on this
            # state, cache window info against preset ID's. These are then used
            # to provide instant status updates.
            #
            # As the device only supports a single connection the only time the
            # cache will contain stale data is following editing of presets, in
            # which case window state will update silently in the background.
            @window_cache ||= {}

            update_cache = deep_query('Windows').then do |windows|
                logger.debug "window cache for preset #{id} updated"
                @window_cache[id] = windows
            end

            update_state = lambda do |windows|
                self[:windows] = windows
                self[:preset]  = id
            end

            if @window_cache.include? id
                logger.debug 'loading cached window state'
                update_state.call @window_cache[id]
            else
                logger.debug "no cached window state available for preset #{id}"
                update_cache.then(&update_state)
            end
        end
    end
    alias switch_to preset

    def switch(signal_map)
        interactions = signal_map.flat_map do |slot, windows|
            Array(windows).map { |id| window id, 'Input', slot }
        end

        thread.finally interactions
    end

    def window(id, property, value)
        id = id.to_s[/\d+/].to_i unless id.is_a? Integer

        set("Window#{id}.#{property}", value).then do
            self[:windows] = (self[:windows] || {}).deep_merge(
                :"window#{id}" => { property.downcase.to_sym => value }
            )
        end
    end


    protected


    def init_connection
        username = setting :username
        password = setting :password

        exec('login', username, password, priority: 99).then { sync_state }
    end

    def do_poll
        logger.debug 'polling device'
        query 'Preset.Take', expose_as: :preset
    end

    # Get the presets available for recall - for some inexplicible reason this
    # has a wildly different API to the rest of the system state...
    def query_preset_list(expose_as: nil)
        exec('Routing.Preset.PresetList').then do |preset_list|
            presets = preset_list.each_with_object({}) do |preset, h|
                key, val = preset.split '='
                id = key[/\d+/].to_i
                name, canvas, time = val.split ','
                h[id] = {
                    name:   name,
                    canvas: canvas,
                    time:   time.to_i
                }
            end

            self[expose_as.to_sym] = presets unless expose_as.nil?

            presets
        end
    end

    def sync_state
        thread.finally(
            query('Preset.Take',   expose_as: :preset),
            query_preset_list(     expose_as: :presets),
            deep_query('Windows',  expose_as: :windows),
            deep_query('Canvases', expose_as: :canvases),
            deep_query('Layouts',  expose_as: :layouts)
        )
    end

    # ------------------------------
    # Base device comms

    def exec(command, *params, **opts)
        logger.debug { "executing #{command}" }

        defer = thread.defer

        opts[:on_receive] = lambda do |*args|
            received(*args) { |val| defer.resolve val }
        end

        send "#{command}(#{params.join ','})\r\n", opts

        defer.promise
    end

    def set(path, val, **opts)
        logger.debug { "setting #{path} to #{val}" }

        defer = thread.defer

        opts[:name] ||= path.to_sym
        send("#{path} = #{val}\r\n", opts).then do
            defer.resolve val
        end

        defer.promise
    end

    def query(path, expose_as: nil, **opts)
        logger.debug { "querying #{path}" }

        defer = thread.defer

        opts[:on_receive] = lambda do |*args|
            received(*args) do |val|
                self[expose_as.to_sym] = val unless expose_as.nil?
                defer.resolve val
            end
        end

        send "#{path}\r\n", opts

        defer.promise
    end

    def deep_query(path, expose_as: nil, **opts)
        logger.debug { "deep querying #{path}" }

        defer = thread.defer

        query(path, opts).then do |val|
            if val.is_a? Hash
                val.each_pair do |k, v|
                    val[k] = deep_query(k).value if v == '<...>'
                end
            end
            self[expose_as] = val unless expose_as.nil?
            defer.resolve val
        end

        defer.promise
    end

    def parse_response(lines, command)
        kv_pairs = lines.map do |line|
            k, v = line.chop.split ' = '
            [k, v]
        end

        updates = kv_pairs.to_h.transform_values! do |val|
            case val
            when /^-?\d+$/    then Integer val
            when 'NULL'       then nil
            when /(Off)|(No)/ then false
            when /(On)|(Yes)/ then true
            else                   val
            end
        end

        if updates.size == 1 && updates.include?(command)
            # Single property query
            updates.values.first
        elsif !updates.empty? && updates.values.all?(&:nil?)
            # Property list
            updates.keys
        else
            # Property set
            updates.reject { |k, _| k.end_with? '()' }
                   .transform_keys! do |x|
                       x.sub(/^#{command}\.?/, '').downcase!.to_sym
                   end
        end
    end

    def tokenize(buffer)
        result_line_start = buffer.index(/^!/)

        return false unless result_line_start

        result_line_end = buffer.index("\r\n", result_line_start)

        if result_line_end
            result_line_end + 2
        else
            false
        end
    end

    def received(data, resolve, command)
        logger.debug { "received: #{data}" }

        *body, result = data.lines
        type, message = /^!(\w+)\W*(.*)\r\n$/.match(result).captures

        case type
        when 'Done'
            if command[:data] =~ /^#{message}/i
                yield parse_response body, message if block_given?
                :success
            else
                :ignore
            end
        when 'Info'
            logger.info message
            yield message if block_given?
            :success
        when 'Error'
            logger.error message
            :fail
        when 'Event'
            logger.warn { "unhandled event: #{message}" }
            :ignore
        else
            logger.error { "unhandled response: #{data}" }
            :abort
        end
    end
end
