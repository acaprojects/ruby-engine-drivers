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
    end
    
    def on_update
    end
    
    def connected
        super

        # Configure in some sane defaults
        do_send 'xConfiguration Standby Control: Off'
        call_status
        @polling_timer = schedule.every('58s') do
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

        command('CamCtrlPip', params({
            :Mode => val
        }), name: :camera_pip).then do
            self[:camera_pip] = feedback
        end
    end

    def toggle_camera_pip
        show_camera_pip !self[:camera_pip]
    end

    CallCommands ||= Set.new([:accept, :reject, :disconnect, :hold, :join, :resume, :ignore])
    def call(cmd, call_id = @last_call_id, **options)
        name = cmd.downcase.to_sym

        command(:call, cmd, params({
            :CallId => call_id
        }), name: name).then do
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


    # Options include: Protocol, CallRate, CallType, DisplayName, Appearance
    def dial(number, options = {})
        options[:Number] = number
        command :dial, params(options)
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

    # Source is a number from 0..15
    def far_end_source(source, call_id = @last_call_id)
        command :FarEndControl, :Source, :Select, "CallId:#{call_id} SourceId:#{source}"
    end



    # Also supports stop
    def presentation(action = :start)

    end

    def save_preset(name)

    end

    def preset(name)

    end

    # pip / 
    def video

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
        if result[1].downcase.to_sym == :resultset
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
        if result[1].downcase.to_sym == :call
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
        end

        :ignore
    end
end

