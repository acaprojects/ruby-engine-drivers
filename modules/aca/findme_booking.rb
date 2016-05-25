require 'thread_safe'

# For rounding up to the nearest 15min
# See: http://stackoverflow.com/questions/449271/how-to-round-a-time-down-to-the-nearest-15-minutes-in-ruby
class ActiveSupport::TimeWithZone
    def ceil(seconds = 60)
        return self if seconds.zero?
        Time.at(((self - self.utc_offset).to_f / seconds).ceil * seconds).in_time_zone + self.utc_offset
    end
end


module Aca; end

# NOTE:: Requires Settings:
# ========================
# room_alias: 'rs.au.syd.L16Aitken',
# building: 'DP3',
# level: '16'

class Aca::FindmeBooking
    include ::Orchestrator::Constants
    EMAIL_CACHE = ::ThreadSafe::Cache.new
    CAN_LDAP = begin
        require 'net/ldap'
        true
    rescue LoadError
        false
    end
    CAN_EWS = begin
        require 'viewpoint'
        true
    rescue LoadError
        false
    end


    descriptive_name 'Findme Room Bookings'
    generic_name :Bookings
    implements :logic


    # The room we are interested in
    default_settings({
        update_every: '5m',
        
        # Moved to System or Zone Setting
        # cancel_meeting_after: 900 

        # Card reader IDs if we want to listen for swipe events
        card_readers: ['reader_id_1', 'reader_id_2'],

        # Optional LDAP creds for looking up emails
        ldap_creds: {
            host: 'ldap.org.com',
            port: 636,
            encryption: :simple_tls,
            auth: {
                  method: :simple,
                  username: 'service account',
                  password: 'password'
            }
        },
        tree_base: "ou=User,ou=Accounts,dc=org,dc=com",

        # Optional EWS for creating and removing bookings
        ews_creds: [
            'https://company.com/EWS/Exchange.asmx',
            'service account',
            'password',
            { http_opts: { ssl_verify_mode: 0 } }
        ],
        ews_room: 'room@email.address'
    })


    def on_load
        @day_checked = [0, 1, 2, 3, 4, 5, 6]
        @day_checking = [nil, nil, nil, nil, nil, nil, nil]

        on_update
    end

    def on_update
        self[:swiped] ||= 0
        @last_swipe_at = 0

        self[:building] = setting(:building)
        self[:level] = setting(:level)
        self[:room] = setting(:room)
        
        # Because restarting the modules results in a 'swipe' of the last read card
        ignore_first_swipe = true

        # Is there catering available for this room?
        self[:catering] = setting(:catering_system_id)
        if self[:catering]
            self[:menu] = setting(:menu)
        end

        # Do we want to look up the users email address?
        if CAN_LDAP
            @ldap_creds = setting(:ldap_creds)
            if @ldap_creds
                @tree_base = setting(:tree_base)
                @ldap_user = @ldap_creds.delete :auth
            end
        else
            logger.warn "net/ldap gem not available" if setting(:ldap_creds)
        end

        # Do we want to use exchange web services to manage bookings
        if CAN_EWS
            @ews_creds = setting(:ews_creds)
            @ews_room = setting(:ews_room) if @ews_creds
        else
            logger.warn "viewpoint gem not available" if setting(:ews_creds)
        end

        # Load the last known values (persisted to the DB)
        self[:waiter_status] = (setting(:waiter_status) || :idle).to_sym
        self[:waiter_call] = self[:waiter_status] != :idle

        self[:catering_status] = setting(:last_catering_status) || {}
        self[:order_status] = :idle

        self[:last_meeting_started] = setting(:last_meeting_started)
        self[:cancel_meeting_after] = setting(:cancel_meeting_after)


        # unsubscribe to all swipe IDs if any are subscribed
        if @subs.present?
            @subs.each do |sub|
                unsubscribe(sub)
            end

            @subs = nil
        end

        # Are there any swipe card integrations
        if system.exists? :Security
            readers = setting(:card_readers)
            if readers.present?
                security = system[:Security]

                readers = readers.is_a?(Array) ? readers : [readers]
                sys = system
                @subs = []
                readers.each do |id|
                    @subs << sys.subscribe(:Security, 1, id.to_s) do |notice|
                        if ignore_first_swipe
                            ignore_first_swipe = false
                        else
                            swipe_occured(notice.value)
                        end
                    end
                end
            end
        end

        fetch_bookings
        @polling_timer.cancel unless @polling_timer.nil?
        @polling_timer = schedule.every(setting(:update_every) || '5m', method(:fetch_bookings))
    end


    # ======================================
    # Waiter call information
    # ======================================
    def waiter_call(state)
        status = is_affirmative?(state)

        self[:waiter_call] = status

        # Used to highlight the service button
        if status
            self[:waiter_status] = :pending
        else
            self[:waiter_status] = :idle
        end

        define_setting(:waiter_status, self[:waiter_status])
    end

    def call_acknowledged
        self[:waiter_status] = :accepted
        define_setting(:waiter_status, self[:waiter_status])
    end


    # ======================================
    # Catering Management
    # ======================================
    def catering_status(details)
        self[:catering_status] = details

        # We'll turn off the green light on the waiter call button
        if self[:waiter_status] != :idle && details[:progress] == 'visited'
            self[:waiter_call] = false
            self[:waiter_status] = :idle
            define_setting(:waiter_status, self[:waiter_status])
        end

        define_setting(:last_catering_status, details)
    end

    def commit_order(order_details)
        self[:order_status] = :pending
        status = self[:catering_status]

        if status && status[:progress] == 'visited'
            status = status.dup
            status[:progress] = 'cleaned'
            self[:catering_status] = status
        end

        if self[:catering]
            sys = system
            @oid ||= 1
            systems(self[:catering])[:Orders].add_order({
                id: "#{sys.id}_#{@oid}",
                created_at: Time.now.to_i,
                room_id: sys.id,
                room_name: sys.name,
                order: order_details
            })
        end
    end

    def order_accepted
        self[:order_status] = :accepted
    end

    def order_complete
        self[:order_status] = :idle
    end



    # ======================================
    # ROOM BOOKINGS:
    # ======================================
    def fetch_bookings(*args)
        # Fetches bookings from now to the end of the day
        findme = system[:FindMe]
        findme.meetings(self[:building], self[:level]).then do |raw|
            correct_level = true
            promises = []
            bookings = []

            raw.each do |value|
                correct_level = false if value[:ConferenceRoomAlias] !~ /#{self[:level]}/
                bookings << value if value[:ConferenceRoomAlias] == self[:room]
            end

            if !correct_level
                logger.warn "May have received the bookings for the wrong level\nExpecting #{self[:building]} level #{self[:level]} and received\n#{raw}"
            end

            if bookings.length > 0 || correct_level
                bookings.each do |booking|
                    username = booking[:BookingUserAlias]
                    if username
                        promise = findme.users_fullname(username)
                        promise.then do |name|
                            booking[:owner] = name
                        end
                        promises << promise
                    end
                end

                thread.all(*promises).then do
                    # UI will assume these are sorted
                    self[:today] = bookings
                end
            end
        end
    end

    def bookings_for(day)
        now = Time.now
        day_num = day.to_i
        current = now.wday

        if day_num != now.wday && @day_checked[day_num] < (now - 5.minutes)
            promise = @day_checking[day_num]
            return promise if promise

            # Clear the old data
            symbol = :"day_#{day_num}"
            self[symbol] = nil

            # We are looking for bookings on another day
            promise = system[:FindMe].meetings(self[:building], self[:level])
            @day_checking[day_num] = promise
            promise.then do |bookings|
                self[symbol] = bookings[self[:room]]
            end
            promise.finally do
                @day_checking[day_num] = nil
            end
        end
    end

    # TODO:: Provide a way to indicate if this succeeded or failed
    #def schedule_meeting(user, starting, ending, subject)
    #    system[:FindMe].schedule_meeting(user, self[:room], starting, ending, subject)
    #end
    #
    # NOTE:: We're using EWS directly now


    # ======================================
    # Meeting Helper Functions
    # ======================================

    def start_meeting(meeting_ref)
        self[:last_meeting_started] = meeting_ref
        define_setting(:last_meeting_started, meeting_ref)
    end

    def cancel_meeting(start_time)
        task {
            delete_ews_booking start_time
        }.then(proc { |count|
            logger.debug { "successfully removed #{count} bookings" }
            # Refresh the panel
            fetch_bookings       
        }, proc { |error|
            logger.print_error error, 'removing ews booking'
        })
    end

    def create_meeting(duration, next_start = nil)
        if next_start
            next_start = Time.parse(next_start.to_s)
        end

        end_time = duration.to_i.minutes.from_now.ceil(15.minutes)
        start_time = Time.now

        # Make sure we don't overlap the next booking
        if next_start && next_start < end_time
            end_time = next_start
        end

        task {
            make_ews_booking start_time, end_time
        }.then(proc { |id|
            logger.debug { "successfully created booking: #{id}" }
            # We want to start the meeting automatically
            start_meeting(start_time.to_i * 1000)
            # Refresh the panel
            fetch_bookings
        }, proc { |error|
            logger.print_error error, 'creating ad hoc booking'
        })
    end


    protected


    def swipe_occured(info)
        # Update the user details
        @last_swipe_at = Time.now.to_i
        self[:fullname] = "#{info[:firstname]} #{info[:lastname]}"
        self[:username] = info[:staff_id]
        email = nil

        if self[:username] && @ldap_creds
            email = EMAIL_CACHE[self[:username]]
            if email
                set_email(email)
                logger.debug { "email #{email} found in cache" }
            else
                # Cache username here as self[:username] might change while we
                #  looking up the previous username
                username = self[:username]

                logger.debug { "looking up email for #{username} - #{self[:fullname]}" }
                task {
                    ldap_lookup_email username
                }.then do |email|
                    if email
                        logger.debug { "email #{email} found in LDAP" }
                        EMAIL_CACHE[username] = email
                        set_email(email)
                    else
                        logger.warn "no email found in LDAP for #{username}"
                        set_email nil
                    end
                end
            end
        else
            logger.warn "no staff ID for user #{self[:fullname]}"
            set_email nil
        end
    end

    def set_email(email)
        self[:email] = email
        self[:swiped] += 1
    end

    # ====================================
    # LDAP lookup to occur in worker thread
    # ====================================
    def ldap_lookup_email(username)
        ldap = Net::LDAP.new @ldap_creds
        ldap.authenticate @ldap_user[:username], @ldap_user[:password] if @ldap_user

        login_filter = Net::LDAP::Filter.eq('sAMAccountName', username)
        object_filter = Net::LDAP::Filter.eq('objectClass', '*')
        treebase = @tree_base
        search_attributes = ['mail']

        email = nil
        ldap.bind
        ldap.search({
            base: treebase,
            filter: object_filter & login_filter,
            attributes: search_attributes
        }) do |entry|
            email = get_attr(entry, 'mail')
        end

        # Returns email as a promise
        email
    end

    def get_attr(entry, attr_name)
        if attr_name != "" && attr_name != nil
            entry[attr_name].is_a?(Array) ? entry[attr_name].first : entry[attr_name]
        end
    end
    # ====================================


    # =======================================
    # EWS Requests to occur in a worker thread
    # =======================================
    def make_ews_booking(start_time, end_time)
        subject = 'Ad hoc Booking'
        user_email = self[:email]

        booking = {
            subject: subject,
            start: start_time,
            end: end_time
        }

        if user_email
            booking[:required_attendees] = [{
                attendee: { mailbox: { email_address: user_email } }
            }]
        end

        opts = {}
        opts[:act_as] = @ews_room if @ews_room

        cli = Viewpoint::EWSClient.new(*@ews_creds)
        folder = cli.get_folder(:calendar, opts)
        appointment = folder.create_item(booking)

        # Return the booking IDs
        appointment.item_id
    end

    def delete_ews_booking(start_time)
        delete_at = Time.parse(start_time.to_s).to_i

        opts = {}
        opts[:act_as] = @ews_room if @ews_room

        count = 0

        cli = Viewpoint::EWSClient.new(*@ews_creds)
        folder = cli.get_folder(:calendar, opts)
        items = folder.items_between(Date.today.iso8601, Date.tomorrow.tomorrow.iso8601)
        items.each do |meeting|
            meeting_time = Time.parse(meeting.ews_item[:start][:text])

            # Remove any meetings that match the start time provided
            if meeting_time.to_i == delete_at
                meeting.delete!(:recycle, send_meeting_cancellations: 'SendOnlyToAll')
                count += 1
            end
        end

        # Return the number of meetings removed
        count
    end
    # =======================================
end
