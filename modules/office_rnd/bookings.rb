
module OfficeRnd; end
class OfficeRnd::Bookings
  include ::Orchestrator::Constants

  # Discovery Information
  descriptive_name 'Office RnD Room Booking Panel Logic'
  generic_name :Bookings
  implements :logic

  default_settings({
    resource_id: "resource_id"
  })

  def on_load
    on_update
  end

  def on_update
    @resource_id = setting(:resource_id)

    self[:room_name] = setting(:room_name) || system.name
    self[:hide_all] = setting(:hide_all) || false
    self[:touch_enabled] = setting(:touch_enabled) || false
    self[:arrow_direction] = setting(:arrow_direction)
    self[:hearing_assistance] = setting(:hearing_assistance)
    self[:timeline_start] = setting(:timeline_start)
    self[:timeline_end] = setting(:timeline_end)
    self[:description] = setting(:description)
    self[:icon] = setting(:icon)
    self[:control_url] = setting(:booking_control_url) || system.config.support_url
    self[:help_options] = setting(:help_options)

    self[:timeout] = setting(:timeout)
    self[:booking_cancel_timeout] = UV::Scheduler.parse_duration(setting(:booking_cancel_timeout)) / 1000 if setting(:booking_cancel_timeout)   # convert '1m2s' to '62'
    self[:booking_cancel_email_message] = setting(:booking_cancel_email_message)
    self[:booking_timeout_email_message] = setting(:booking_timeout_email_message)
    self[:booking_controls] = setting(:booking_controls)
    self[:booking_catering] = setting(:booking_catering)
    self[:booking_hide_details] = setting(:booking_hide_details)
    self[:booking_hide_availability] = setting(:booking_hide_availability)
    self[:booking_hide_user] = setting(:booking_hide_user)
    self[:booking_hide_modal] = setting(:booking_hide_modal)
    self[:booking_hide_title] = setting(:booking_hide_title)
    self[:booking_hide_description] = setting(:booking_hide_description)
    self[:booking_hide_timeline] = setting(:booking_hide_timeline)
    self[:booking_set_host] = setting(:booking_set_host)
    self[:booking_set_title] = setting(:booking_set_title)
    self[:booking_set_ext] = setting(:booking_set_ext)
    self[:booking_search_user] = setting(:booking_search_user)
    self[:booking_disable_future] = setting(:booking_disable_future)
    self[:booking_min_duration] = setting(:booking_min_duration)
    self[:booking_max_duration] = setting(:booking_max_duration)
    self[:booking_duration_step] = setting(:booking_duration_step)
    self[:booking_endable] = setting(:booking_endable)
    self[:booking_ask_cancel] = setting(:booking_ask_cancel)
    self[:booking_ask_end] = setting(:booking_ask_end)
    self[:booking_default_title] = setting(:booking_default_title) || "On the spot booking"
    self[:booking_select_free] = setting(:booking_select_free)
    self[:booking_hide_all] = setting(:booking_hide_all) || false

    self[:last_meeting_started] = setting(:last_meeting_started)
    self[:cancel_meeting_after] = setting(:cancel_meeting_after)

    schedule.clear
    schedule.in(rand(20000)) { fetch_bookings }
    schedule.every(30000 + rand(60000)) { fetch_bookings }
    schedule.every(30000) { check_room_usage }
  end

  def fetch_bookings
    logger.debug { "looking up todays bookings for #{@resource_id}" }
    officernd = system[:OfficeRnD]
    officernd.resource_bookings(@resource_id).then do |bookings|
      self[:today] = bookings.map do |booking|
        staff_details = officernd.staff_details(booking[:member]).value
        {
          id: booking[:bookingId],
          Start: booking[:start][:dateTime],
          End: booking[:end][:dateTime],
          Subject: booking[:summary],
          owner: staff_details[:name],
          setup: 0,
          breakdown: 0,
          start_epoch: Time.parse(booking[:start][:dateTime]).to_i,
          end_epoch: Time.parse(booking[:end][:dateTime]).to_i
        }
      end

      check_room_usage
    end
  end

  def check_room_usage
    now = Time.now.to_i
    current_booking = false

    bookings = self[:today] || []
    bookings.each do |booking|
      if now < booking[:end_epoch] && now > booking[:start_epoch]
        current_booking = true
        break
      end
    end

    self[:room_in_use] = current_booking
  end
end
