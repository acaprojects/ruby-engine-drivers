module Amx; end
module Amx::Svsi; end


class Amx::Svsi::NSeriesSwitcher
    include ::Orchestrator::Constants
    include ::Orchestrator::Transcoder


    # Discovery Information
    tcp_port 50020
    descriptive_name 'AMX SVSI N-Series Switcher'
    generic_name :Switcher

    # Communication settings
    tokenize indicator: '<status>', delimiter: '</status>'
    wait_response false


    def on_load
        self[:volume_min] = 0
        self[:volume_max] = 100
        on_update
    end

    def on_update
        # { 'ip_address or stream number': 'input description / location' }
        @inputs = setting(:inputs) || {}

        # { 'ip_address': 'output description / location' }
        @outputs = setting(:outputs) || {}

        @encoders = @inputs.keys
        @decoders = @outputs.keys

        @lookup = @inputs.merge(@outputs)
        @list   = @encoders + @decoders
    end
    
    def connected
        # Get current state of the outputs
        @lookup.each_key do |ip_address|
            monitor        ip_address, priority: 0
            monitornotify  ip_address, priority: 0
        end

        # Low priority poll to maintain connection
        @polling_timer = schedule.every('50s') do
            logger.debug '-- Maintaining Connection --'
            monitornotify @list.first, priority: 0
        end
    end

    def disconnected
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end


    # Automatically creates a callable function for each command
    #    http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #    http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    CommonCommands = [
        :monitor, :monitornotify,
        :live, :local, :serial, :readresponse, :sendir, :sendirraw, :audioon, :audiooff,
        :enablehdmiaudio, :disablehdmiaudio, :autohdmiaudio,
        # recorder commands
        :record, :dsrecord, :dvrswitch1, :dvrswitch2, :mpeg, :mpegall, :deletempegfile,
        :play, :stop, :pause, :unpause, :fastforward, :rewind, :deletefile, :stepforward,
        :stepreverse, :stoprecord, :recordhold, :recordrelease, :playhold, :playrelease,
        :deleteallplaylist, :deleteallmpegs, :remotecopy,
        # window processor commands
        :wpswitch, :wpaudioin, :wpactive, :wpinactive, :wpaudioon, :wpaudiooff, :wpmodeon,
        :wpmodeoff, :wparrange, :wpbackground, :wpcrop, :wppriority, :wpbordon, :wpbordoff,
        :wppreset,
        # audio transceiver commands
        :atrswitch, :atrmute, :atrunmute, :atrtxmute, :atrtxunmute, :atrhpvol, :atrlovol,
        :atrlovolup, :atrlovoldown, :atrhpvolup, :atrhpvoldown, :openrelay, :closerelay,
        # video wall commands
        :videowall,
        # miscellaneous commands
        :script, :goto, :tcpclient, :udpclient, :reboot, :gc_serial, :gc_openrelay,
        :gc_closerelay, :gc_ir
    ]

    CommonCommands.each do |command|
        define_method command do |ip_address, *args, **options|
            do_send(command, ip_address, *args, **options)
        end
    end

    def serialhex(ip_address, *data, wait_time: 1, **options)
        do_send(:serialhex, wait_time, ip_address, *data, **options)
    end


    # ================
    # Encoder Commands
    # ================

    EncoderCommands = [:modeoff, :enablecc, :disablecc, :autocc, :uncompressedoff]

    EncoderCommands.each do |command|
        define_method command do |input, *args, **options|
            do_send(command, get_input(input), *args, **options)
        end
    end


    # ================
    # Decoder Commands
    # ================

    DecoderCommands = [:audiofollow, :volume, :dvion, :dvioff, :cropref, :getStatus]

    DecoderCommands.each do |command|
        define_method command do |output, *args, **options|
            do_send(command, get_output(output), *args, **options)
        end
    end

    def switch(input, output = nil, **options)
        map = output ? {input => output} : input
        map.each do |input, output|
            # An input might go to multiple outputs
            outputs = Array(output)

            if input != 0
                # 'in_ip' => ['ip1', 'ip2'] etc
                input_actual = get_input(input)
                outputs.each do |out|
                    output_actual = get_output(out)

                    dvion output_actual, **options
                    audioon output_actual, **options
                    audiofollow output_actual, **options

                    self[:"video#{output_actual}"] = input_actual
                    self[:"audio#{output_actual}"] = input_actual
                    do_send :switch, output_actual, input_actual, **options
                end
            else
                # nil => ['ip1', 'ip2'] etc
                outputs.each do |out|
                    output_actual = get_output(out)

                    dvioff   output_actual, **options
                    audiooff output_actual, **options
                end
            end
        end
    end
    alias_method :switch_video, :switch

    def switch_audio(input, output = nil, **options)
        map = output ? {input => output} : input
        map.each do |input, output|
            # An input might go to multiple outputs
            outputs = Array(output)

            if input != 0
                # 'in_ip' => ['ip1', 'ip2'] etc
                input_actual = get_input(input)
                outputs.each do |out|
                    output_actual = get_output(out)

                    audioon input_actual,  **options
                    audioon output_actual, **options

                    self[:"audio#{output_actual}"] = input_actual
                    do_send :switchaudio, output_actual, input_actual, **options
                end
            else
                # nil => ['ip1', 'ip2'] etc
                outputs.each do |out|
                    audiooff get_output(out), **options
                end
            end
        end
    end


    def mute_video(out, state = true, **options)
        outputs = Array(out)

        if is_affirmative?(state)
            outputs.each { |out| dvioff(out, **options) }
        else
            outputs.each { |out| dvion(out, **options) }
        end
    end

    def mute_audio(out, state = true, **options)
        outputs = Array(out)

        if is_affirmative?(state)
            outputs.each { |out| audiooff(out, **options) }
        else
            outputs.each { |out| audioon(out, **options) }
        end
    end

    def unmute_video(out)
        mute_video out, false
    end

    def unmute_audio(out)
        mute_audio out, false
    end

    # ===================
    # Response Processing
    # ===================
    def received(data, resolve, command)
        logger.debug { "received #{data}" }

        resp = data.split(";")
        case resp.length
        when 13 # Encoder or decoder status
            is_output = !@outputs[resp[0]].nil?
            self[resp[0]] = {
                communications: resp[1] == '1',
                dvioff: resp[2] == '1',
                scaler: resp[3] == '1',
                source_detected: resp[4] == '1',
                mode: resp[5],
                audio_enabled: resp[6] == '1',
                video_stream: resp[7].to_i,
                audio_stream: resp[8] == 'follow video' ? resp[8] : resp[8].to_i,
                playlist: resp[9],
                colorspace: resp[10],
                hdmiaudio: resp[11],
                resolution: resp[12]
            }
        when 10 # Audio Transceiver or window processor status
            self[resp[0]] = resp
        else
            logger.warn "unknown response type: #{resp}"
        end
        
        return :success
    end


    protected


    def do_send(*args, **options)
        cmd = args.join(' ')
        logger.debug { "sending #{cmd}" }
        send("#{cmd}\r\n", options)
    end

    def get_input(address)
        if @inputs[address]
            address
        else # We're looking for an index
            @encoders[address]
        end
    rescue => e
        logger.warn "unknown address #{address}: #{e.message}\nat: #{e.backtrace[0]}"

        address
    end

    def get_output(address)
        if @outputs[address]
            address
        else # We're looking for an index
            @decoders[address]
        end
    rescue => e
        logger.warn "unknown address #{address}: #{e.message}\nat: #{e.backtrace[0]}"

        address
    end
end
