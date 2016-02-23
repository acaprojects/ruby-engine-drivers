load File.expand_path('./sx_telnet.rb', File.dirname(__FILE__))


class Cisco::TelePresence::SxSeries < Cisco::TelePresence::SxTelnet
    # Discovery Information
    descriptive_name 'Cisco TelePresence'
    generic_name :VidConf

    tokenize delimiter: "\r",
             wait_ready: "login:"
    clear_queue_on_disconnect!


    def on_load
        super

        self[:presentation] = :none
        on_update
    end
    
    def on_update
        @default_source = setting(:presentation) || 3
    end
    
    def connected
        super

        # Configure in some sane defaults
        do_send 'xConfiguration Standby Control: Off'
        call_status
        pip_mode?
        @polling_timer = schedule.every('5s') do
            logger.debug "-- Polling Cisco SX"
            call_status
        end
    end
    
    def disconnected
        super

        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = nil
    end



    # ================
    # Common functions
    # ================

    def show_camera_pip(value)
        feedback = is_affirmative?(value)
        val = feedback ? 'On' : 'Off'

        command('Video Selfview Set', params({
            :Mode => val
        }), name: :camera_pip).then do
            self[:camera_pip] = feedback
        end
    end

    def toggle_camera_pip
        show_camera_pip !self[:camera_pip]
    end

    def pip_mode?
        status 'Video Selfview Mode'
    end


    # Options include: Protocol, CallRate, CallType, DisplayName, Appearance
    def dial(number, options = {})
        checkBooking = number.split('@')
        if checkBooking.length > 1
            options[:BookingId] = checkBooking[0]
            options[:Number] = checkBooking[1]
        else
            options[:Number] = number
        end

        command(:dial, params(options), name: :dial, delay: 500).then do
            call_status
        end
    end

    CallCommands ||= Set.new([:accept, :reject, :disconnect, :hold, :join, :resume, :ignore])
    def call(cmd, call_id = @last_call_id, **options)
        name = cmd.downcase.to_sym

        command(:call, cmd, params({
            :CallId => call_id
        }), name: name, delay: 500).then do
            call_status
        end
    end

    def call_status
        status(:call, name: :call)
    end

    SearchDefaults = {
        :PhonebookType => :Local, # Should probably make this a setting
        :Limit => 10,
        :ContactType => :Contact,
        :SearchField => :Name
    }
    def search(text, opts = {})
        opts = SearchDefaults.merge(opts)
        opts[:SearchString] = text
        command(:phonebook, :search, params(opts), name: :phonebook, max_waits: 400)
    end

    # Options include: auto, custom, equal, fullscreen, overlay, presentationlargespeaker, presentationsmallspeaker, prominent, single, speaker_full
    def layout(mode, target = :local)
        self[:"layout_#{target}"] = mode

        command(:Video, :PictureLayoutSet, params({
            :Target => target,
            :LayoutFamily => mode
        }), name: :layout)
    end


    def send_DTMF(string, call_id = @last_call_id)
        command(:DTMFSend, params({
            :CallId => call_id,
            :DTMFString => string
        }))
    end


    # Valid values: none, local, remote
    PresModes = {
        local: :LocalOnly,
        remote: :LocalRemote
    }
    def presentation_mode(value, source = @default_source)
        status = value.to_sym
        mode = PresModes[status]

        if mode
            command('Presentation Start', params({
                :SendingMode => mode,
                :PresentationSource => source
            }), name: :presentation).then do
                self[:presentation] = status
            end
        else
            command 'Presentation Stop'
            self[:presentation] = :none
        end
    end

    def content_available?
        status 'Conference Presentation Mode'
    end

    def select_camera(index)
        # NOTE:: Index should be a number
        command('Video Input SetMainVideoSource', params({
            :ConnectorId => index
        }), name: :select_camera)
    end

    def select_presentation(index)
        # NOTE:: Index should be a number
        command('xConfiguration Video', params({
            :DefaultPresentationSource => index
        }), name: :select_presentation)
    end

    # ====================
    # END Common functions
    # ====================


    # ===========================================
    # IR REMOTE KEYS (NOT AVAILABLE IN SX SERIES)
    # ===========================================

=begin
    RemoteKeys = ['0','1','2','3','4','5','6','7','8','9',
                  'Star','Square','Call','Disconnect',
                  'Up','Down','Right','Left','Selfview',
                  'Layout','PhoneBook','C','MuteMic','Presentation',
                  'VolumeUp','VolumeDown','Ok','ZoomIn','ZoomOut','Grab',
                  'F1','F2','F3','F4','F5','Home','Mute',
                  'SrcAux','SrcCamera','SrcDocCam','SrcPc','SrcVcr']

    #
    # Automatically creates a callable function for each command
    #   http://blog.jayfields.com/2007/10/ruby-defining-class-methods.html
    #   http://blog.jayfields.com/2008/02/ruby-dynamically-define-method.html
    #
    RemoteKeys.each do |key|
        define_method :"key_#{key.underscore}" do |**options|
            command("Key Click Key:#{key}", **options)
        end
    end
=end

    # ==================
    # END IR REMOTE KEYS
    # ==================


    def audio(*args, **options)
        command :audio, *args, params(options)
    end

    def history(cmd, options = {})
        command :CallHistroy, cmd, params(options)
    end

    # left, right, up, down, zoomin, zoomout
    def far_end_camera(action, call_id = @last_call_id)
        req = action.downcase.to_sym
        if req == :stop
            command :FarEndControl, :Camera, :Stop, "CallId:#{call_id}"
        else
            command :FarEndControl, :Camera, :Move, "CallId:#{call_id} Value:#{req}"
        end
    end

    
    
    ResponseType = {
        '**' => :complete,
        '*r' => :results,
        '*s' => :status
    }
    def received(data, resolve, command)
        logger.debug { "Tele sent #{data}" }

        result = Shellwords.split data
        response = ResponseType[result[0]]

        if command
            if response == :complete
                # Update status variables
                if @listing_phonebook
                    @listing_phonebook = false

                    # expose results
                    self[:search_results] = @results
                elsif @call_status
                    @call_status[:id] = @last_call_id
                    self[:call_status] = @call_status
                    if @call_status.empty?
                        self[:content_available] = false
                    else
                        content_available?
                        if @call_status[:status] == 'OnHold'
                            self[:presentation] = :none
                        end
                    end
                    @call_status = nil
                elsif command[:name] == :call
                    if self[:call_status].present?
                        self[:previous_call] = self[:call_status][:callbacknumber]
                    end

                    self[:call_status] = {}
                    @last_call_id = nil
                    @call_status = nil
                end
                return :success
            elsif response.nil?
                return :ignore
            end
        end

        return case response
        when :status
            process_status result
        when :results
            process_results result
        else
            :success
        end
    end


    protected


    def process_results(result)
        case result[1].downcase.to_sym
        when :resultset
            @listing_phonebook = true

            case result[2]

            # Looks like: *r ResultSet ResultInfo TotalRows: 3
            when 'ResultInfo'
                if result[3] == 'TotalRows:'
                    self[:results_total] = result[4].to_i
                    @results = []
                end

            when 'Contact'
                contact = @results[result[3].to_i - 1]
                if contact.nil?
                    contact = {
                        methods: []
                    }
                    @results << contact
                end

                if result[4] == 'ContactMethod'
                    # Looks like: *r ResultSet Contact 1 ContactMethod 1 Number: "10.243.218.232"
                    method = contact[:methods][result[5].to_i - 1]
                    if method.nil?
                        method = {}
                        contact[:methods] << method
                    end

                    entry = result[6].chop
                    method[entry.downcase.to_sym] = result[7]
                else
                    # Looks like: *r ResultSet Contact 2 Name: "Some Room"
                    entry = result[4].chop
                    contact[entry.downcase.to_sym] = result[5]
                end
            end
        end

        :ignore
    end

    def process_status(result)
        case result[1].downcase.to_sym
        when :call
            # Looks like: *s Call 32 CallbackNumber: "h323:10.243.218.234"

            @call_status ||= {}
            @last_call_id = result[2].to_i

            # NOTE: special case for "Encryption Type:"
            entry = result[3].chop.downcase.to_sym
            if entry == :encryptio
                @call_status[:encryption] = result[5]
            else
                @call_status[entry] = result[4]
            end
        when :conference
            if result[2] == 'Presentation' && result[3] == 'Mode:'
                self[:content_available] = result[4] != 'Off'
                if result[4] == 'Receiving'
                    # Then we are not sending anything
                    self[:presentation] = :none
                end
            end
        when :Video
            if result[2] == 'Selfview' && result[3] == 'Mode:'
                self[:camera_pip] = result[4] == 'On'
            end
        end

        :ignore
    end
end

