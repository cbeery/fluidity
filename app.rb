require 'sinatra'
require 'sinatra/reloader' if development?
require 'google/apis/sheets_v4'
require 'signet/oauth_2/client'
require 'dotenv/load'
require 'active_support/time'
require 'icalendar'

before '/api/*' do
	content_type 'application/json'
end

before do
	drive_setup
end

get '/api/latest' do
	fluids = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Fluids').values
	latest = fluids.last
	data = {when: latest[0], data: latest.drop(1)}
	data.to_json
end

get '/api/purveyors' do
	catalog = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Catalog').values
	catalog.map{|c| c[0]}.to_json
end

get '/api/catalog' do
	venue = params[:venue]
	catalog = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Catalog').values
	lookup = {}
	catalog.each{|c| lookup[c[0]] = c.drop(1)}
	response = lookup[venue]
	response.to_json
end

get '/api/lists' do
	lists = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Lists').values
	response = {venues: lists[0], sizes: lists[1], vessels: lists[2]}
	response.to_json
end

post '/api/add' do
	check_passphrase

	purchased = params[:purchased]
	item = params[:item]
	oz = params[:oz]
	vessel = params[:vessel]
	consumed = params[:consumed]
	consumed_at = timestamp

	value_range = Google::Apis::SheetsV4::ValueRange.new(values: [[consumed_at, purchased, item, oz, vessel, consumed]])
	result = @drive.append_spreadsheet_value(ENV['SHEET_ID'], 'Fluids!A:F', value_range, value_input_option: 'RAW')
	response = "Added: #{item} / #{oz} / #{vessel} at #{consumed_at}.".to_json
end

post '/api/dup' do
	check_passphrase

	consumed_at = timestamp
	fluids = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Fluids').values
	latest = fluids.last

	value_range = Google::Apis::SheetsV4::ValueRange.new(values: [latest.drop(1).unshift(consumed_at)])
	result = @drive.append_spreadsheet_value(ENV['SHEET_ID'], 'Fluids!A:F', value_range, value_input_option: 'RAW')
	response = "Duplicated: #{latest[2]} / #{latest[3]} / #{latest[4]} at #{consumed_at}.".to_json
end

get '/' do
	'hello'
end

get '/cal' do
	cal = Icalendar::Calendar.new
	timezone_setup(cal)
	convert_spreadsheet_rows_to_cal(cal)
end


private

def drive_setup
	auth = Signet::OAuth2::Client.new(
	  token_credential_uri: 'https://accounts.google.com/o/oauth2/token',
	  client_id: 						ENV['GOOGLE_CLIENT_ID'],
	  client_secret: 				ENV['GOOGLE_CLIENT_SECRET'],
	  refresh_token: 				ENV['REFRESH_TOKEN']
	)
	auth.fetch_access_token!
	@drive = Google::Apis::SheetsV4::SheetsService.new
	@drive.authorization = auth
end

def timestamp
	Time.now.in_time_zone('US/Mountain').strftime("%a %b %e %Y %l:%M %p")
end

def check_passphrase
	unless params[:passphrase] && params[:passphrase] == ENV['PASSPHRASE']
		halt 401, {'Content-Type' => 'application/json'}, 'bad passphrase, sorry'
	end
end

def timezone_setup(cal)
	# TimeZone
	cal.timezone do |t|
		t.tzid = "America/Denver"

		t.daylight do |d|
			d.tzoffsetfrom = "-0700"
			d.tzoffsetto   = "-0600"
			d.tzname       = "MDT"
			d.dtstart      = "19700308T020000"
			d.rrule        = "FREQ=YEARLY;BYMONTH=3;BYDAY=2SU"
		end # daylight

		t.standard do |s|
			s.tzoffsetfrom = "-0600"
			s.tzoffsetto   = "-0700"
			s.tzname       = "MST"
			s.dtstart      = "19701101T020000"
			s.rrule        = "FREQ=YEARLY;BYMONTH=11;BYDAY=1SU"
		end # standard
	end # timezone
end

def convert_spreadsheet_rows_to_cal(cal)
	fluids = @drive.get_spreadsheet_values(ENV['SHEET_ID'], 'Fluids').values
	@rows = fluids.drop(1) # .drop ignores header row
	@rows.each_with_index do |row, index|
    cal.event do |e|
    	start = DateTime.parse(row[0]) # Column A = date
      e.dtstart     = Icalendar::Values::DateTime.new(start)
      e.dtend       = Icalendar::Values::DateTime.new(start + 15.minutes)
      e.summary 		= "#{row[2]} / #{row[3]}" # Item / oz
      e.location		= row[1] # Purchased
      e.description = "#{row[5]}, #{row[4]} #{"("+row[6]+")" unless row[6].blank?}" # Consumed, Vessel (Notes)
      e.uid					= "fluids#{index + 1}"
    end # cal.event
	end # @rows.each
	# cal.to_ical.html_safe
	cal.to_ical.to_s
end

