require 'nlims_service.rb'
class Sender

	def self.send_data(patient, specimen)
    order = {
        "_id" => specimen.tracking_number,
        "sample_status" => SpecimenStatus.find(specimen.specimen_status_id).name.titleize
    }
    configs = YAML.load_file("#{Rails.root}/config/nlims_connection.yml")

    if configs['nlims_controller'] == true
        update_details = {
          "tracking_number": order['_id']
        }
        tests = specimen.tests
        tests.each  do |test|
            who = User.current
            updater = {}
            results = {}
            test_name = test.test_type.name
            update_details['test_name'] = test_name
            update_details['test_status'] = TestStatus.find(test.test_status_id).name
            update_details['time_update'] = Date.today.strftime("%a %b %d %Y")

            updater = {
              'first_name': who.name.strip.scan(/^\w+/).first,
              'last_name': who.name.strip.scan(/\w+$/).last,
              'id_number': who.id
            }

            update_details['who_updated'] = updater        
            order['results'] = {} if order['results'].blank?            
            r = {}

            test.test_results.each do |result|
              measure = Measure.find(result.measure_id) rescue next
              r["#{measure.name}"] = "#{result.result} #{measure.unit}"
            end

            update_details['results'] = r
        end

        res = NlimsService.update_test(update_details)

        if res == true
          puts res

        else


        end

    else

        tests = specimen.tests
        tests.each  do |test|
          test_name = test.test_type.name
          order['results'] = {} if order['results'].blank?
          order['results']["#{test_name}"] = {} if order['results']["#{test_name}"].blank?

          h = {}
          h['test_status'] = TestStatus.find(test.test_status_id).name
          h['remarks'] = test.interpretation
          h['datetime_started'] = test.time_started.to_datetime rescue ''
          h['datetime_completed'] = test.time_completed.to_datetime rescue ''

          h['who_updated'] = {} if test['who_updated'].blank?
          who = User.current
          h['who_updated']['first_name'] = who.name.strip.scan(/^\w+/).first
          h['who_updated']['last_name'] = who.name.strip.scan(/\w+$/).last
          h['who_updated']['ID_number'] = who.id

          r = {}

          test.test_results.each do |result|
            measure = Measure.find(result.measure_id) rescue next
            r["#{measure.name}"] = "#{result.result} #{measure.unit}"
          end

          h['results'] = r
          order['results']["#{test.name}"] = h
        end

        settings = YAML.load_file("#{Rails.root}/config/application.yml")[Rails.env]
        remote_post_url = "#{settings['central_repo']}/pass_json/"

        order = RestClient.post(remote_post_url, order.to_json, "content_type" => "application/json")

        order
    end

  end

end

