require 'will_paginate/array' 
require 'nlims_service.rb'
require 'test_utils.rb'

class TestController < ApplicationController
  skip_before_action :verify_authenticity_token
  def index

    accession_number_filter = ""
    settings = YAML.load_file("#{Rails.root}/config/application.yml") #[Rails.env]

    if !params[:tracking_number].blank? && params[:tracking_number].match(/^X/i)
      accession_number_filter = " AND tests.specimen_id IN (SELECT id FROM specimens WHERE tracking_number = '#{params[:tracking_number]}') "
    end

    if !params[:tracking_number].blank? && params[:tracking_number].match(/^\d+$/)
      acc_num = settings["facility_code"] + params[:tracking_number]
      accession_number_filter = " AND tests.specimen_id IN (SELECT id FROM specimens WHERE accession_number = '#{acc_num}') "
    end

    if params[:status] == 'all'
      if params[:patient_id].blank? #pull tests for all patients
        if params[:test_status_id] and params[:test_status_id].to_i != 0
          tests = Test.find_by_sql("SELECT * FROm tests WHERE test_status_id = #{params[:test_status_id]} #{accession_number_filter}
                                    ORDER BY time_created DESC LIMIT 100")
        else
          tests = Test.find_by_sql("SELECT * FROM tests WHERE true #{accession_number_filter} ORDER BY time_created DESC LIMIT 100")
        end
      else #pull tests for one patient
        if params[:test_status_id] and params[:test_status_id].to_i != 0
          tests = Test.find_by_sql("SELECT * FROM tests where test_status_id = #{params[:test_status_id]}
                              AND visit_id IN  (SELECT id FROM visits WHERE patient_id = #{params[:patient_id]}) #{accession_number_filter}
                              ORDER BY time_created DESC LIMIT 100")
        else
          tests = Test.find_by_sql("SELECT * FROM tests where visit_id IN  (SELECT id FROM visits WHERE patient_id = #{params[:patient_id]}) #{accession_number_filter}
                              ORDER BY time_created DESC LIMIT 100")
        end
      end
    end

    @tests = []
    panels = []
    (tests || []).each do |test|
      test_name = test.test_type.name
      next if panels.include?(test.panel_id)

      unless test.panel_id.blank?
        test_name = TestPanel.find(test.panel_id).panel_type.name
        panels << test.panel_id
      end

      @tests << {
        :tracking_number => test.specimen.tracking_number,
        :location => test.visit.ward_or_location,
        :date_ordered =>  test.time_created,
        :test_name => test_name,
        :status => test.status.name,
        :specimen_name => test.specimen.specimen_type.name,
        :specimen_id => test.specimen.id,
        :patient_id => test.visit.patient.id,
        :patient_number => test.visit.patient.patient_number,
        :visit_number => test.visit.id,
        :external_patient_number => test.visit.patient.external_patient_number,
        :accession_number => test.specimen.accession_number,
        :test_id => test.id,
        :specimen_status => test.specimen.status.name,
        :test_status => test.status.name,
        :patient_name => "#{test.visit.patient.name} (#{test.visit.patient.gender == 0 ? 'M' : 'F'},#{(test.visit.patient.age rescue 'N/A')})"}
    end

  end

  def new
    @patient = Patient.find(params[:patient_id])
    other_type = SpecimenType.find_by_name('Other')
    @specimen_types = [[]] + (SpecimenType.all().collect{|type| [type['name'], type.id]} - [['Other', other_type.id]]).sort + [['Other', other_type.id]]
    @visit_types = [[]] + VisitType.all().collect{|visit| [visit['name'], visit.id]}
  end

  def types

    specimen_type_id = (params[:filter_value])

    tests = []

    testtypes = TestType.find_by_sql("SELECT * FROM test_types
                  WHERE orderable_test = 1 AND id IN (SELECT test_type_id FROM testtype_specimentypes WHERE specimen_type_id = #{specimen_type_id})")
    stype = SpecimenType.find(specimen_type_id).name

    to_remove = []
    panelS = []

    to_remove = ['CSF Analysis'] if stype != 'CSF'

    to_remove  += ['Sterile Fluid Analysis']  if !(['Ascitic Fluid', 'Pleural Fluid', 'Pericardial Fluid', 'Peritoneal Fluid'].include?(stype))

    to_remove += ['Urine Analysis'] if stype != 'Urine'

    paneled_tests = []

    testtypes.each do |type|
      tname = type.name
      tests << tname
      panel = Panel.where(:test_type_id => type.id) rescue nil
      unless panel.blank?
        panel.each do |p|
          pname = p.panel_type.name
          panelS << pname
          if !tests.include?(pname)
            tests << pname
          end
          paneled_tests << tname if (to_remove.include?(p.panel_type.name) rescue false)
        end
      end
    end

    tests = tests.reject{|w| !w.match(/#{params[:search_string]}/i)}
    panelS = panelS.reject{|w| !w.match(/#{params[:search_string]}/i)}
    tests.sort!
    tests = (panelS + tests).uniq - paneled_tests - to_remove

    render :text => "<li>" + tests.uniq.map{|n| n } .join("</li><li>") + "</li>"
  end

  def check_clinician
	name = params[:clinician]
       
    if (clinician == "unknown" || clinician == "Unknown")
        redirect_to("/test/new?patient_id=#{params[:patient_id]}", flash: {error: 'clinician can not be unknown'})   
    end
    render :text => "good"
  end
  def create
    settings = YAML.load_file("#{Rails.root}/config/application.yml")
    patient = Patient.find(params[:patient_id])
    nlims = YAML.load_file("#{Rails.root}/config/nlims_connection.yml")  
    #status = ApplicationController.up?("#{nlims['nlims_service']}")

    #Patient Details
    first_name = patient.name.strip.scan(/^\w+\s/).first
    last_name = patient.name.strip.scan(/\s\w+$/).last
    middle_name = patient.name.strip.scan(/\s\w+\s/).last
	
    date_sample_collected = params[:day_sample_collected].to_s + " " + params[:time_sample_collected].to_s
    date_sample_collected = date_sample_collected.to_time.strftime("%Y%m%d%H%M%S")     


    #Orderer
		clinician = CGI.unescapeHTML(params[:clinician].strip).split(/\s+/)
    c_last_name = clinician.last
    c_first_name = (clinician - [c_last_name]).join(" ")
    clinician = CGI.unescapeHTML(params[:clinician].strip)
    if (clinician == "unknown" || clinician == "Unknown")
        redirect_to("/test/new?patient_id=#{params[:patient_id]}", flash: {error: 'clinician can not be unknown'})
    else

          json = {
             :district => settings['district'],
             :health_facility_name => settings['facility_name'],
             :first_name=> first_name,
             :last_name=> last_name,
             :middle_name=> middle_name,
             :date_of_birth=> patient.dob.to_date.strftime("%a %b %d %Y"),
             :gender=> (patient.gender == 1 ? "F" : "M"),
             :patient_residence => "",
             :patient_location => "",
             :patient_town => "",
             :patient_district => "",
             :national_patient_id=>  '000000',
             :phone_number=> '',
             :reason_for_test=> '',
             :who_order_test_last_name=> c_last_name,
             :who_order_test_first_name=> c_first_name,
             :who_order_test_phone_number=> '',
             :who_order_test_id=> '',
             :order_location=> params[:ward],
             :sample_type=> SpecimenType.find(params[:specimen_type]).name,
             :date_sample_drawn=> date_sample_collected,
             :tests=> params[:test_types].collect{|t| CGI.unescapeHTML(t)},
             :sample_status => 'specimen_not_collected',
             :sample_priority=> params[:priority] || 'Routine',
             :target_lab=> settings['facility_name'],
             :art_start_date => "",
             :date_received => Time.now,
             :requesting_clinician => '',
             :return_json => 'true'
          }
   
              res = NlimsService.create_local_tracking_number
              NlimsService.prepare_next_tracking_number            
              tracking_number = res

              acc_num = TestUtils.new_accession_number
              visit = Visit.new
              visit.patient_id = params[:patient_id]
              visit.visit_type = VisitType::find(params[:visit_type]).name
              visit.ward_or_location = params[:ward]
              visit.save

              if !params[:test_types].blank?
                specimen = Specimen.new
                specimen.specimen_type_id = params[:specimen_type]
                specimen.accepted_by = User.current.id
                specimen.priority = params[:priority].blank? ? 'Routine' : params[:priority]
                specimen.accession_number = acc_num
                specimen.tracking_number = tracking_number              
                specimen.save
              end
              
              
                order = UnsyncOrder.new
                order.specimen_id = specimen.id
                order.data_not_synced = 'new order'    
                order.data_level = 'specimen'
                order.sync_status = 'not-synced'
                order.updated_by_name = User.current.name
                order.updated_by_id = User.current.id
                order.save
              

              params[:test_types].each do |name|
                name = CGI.unescapeHTML(name)
                type = TestType.find_by_name(name)
                panel_type = PanelType.find_by_name(name)

                if !panel_type.blank?
                  member_tests = Panel.where(:panel_type_id => panel_type.id)

                  test_panel = TestPanel.new
                  test_panel.panel_type_id = panel_type.id
                  test_panel.save

                  (member_tests || []).each do |m_test|
                    test = Test.new
                    test.visit_id = visit.id
                    test.test_type_id = m_test.test_type_id
                    test.specimen_id = specimen.id
                    test.test_status_id = 2
                    test.not_done_reasons = 0
                    test.person_talked_to_for_not_done = 0
                    test.created_by = User.current.id
                    test.panel_id = test_panel.id
                    test.requested_by = clinician
                    test.save
                  end
                else
                  test = Test.new
                  test.visit_id = visit.id
                  test.test_type_id = type.id
                  test.specimen_id = specimen.id
                  test.test_status_id = 2
                  test.not_done_reasons = 0
                  test.person_talked_to_for_not_done = 0
                  test.created_by = User.current.id
                  test.requested_by = clinician
                  test.save
                end
              end
              # Sender.send_data(patient, specimen)
              
              print_and_redirect("/test/print_accession_number?specimen_id=#{specimen.id}", "/tests/all?patient_id=#{visit.patient_id}&show_actions=true")
   end
  end

  def accept

    settings = YAML.load_file("#{Rails.root}/config/application.yml")
    nlims = YAML.load_file("#{Rails.root}/config/nlims_connection.yml")  
    status = ApplicationController.up?("#{nlims['nlims_service']}")
   
    specimen = Specimen.find(params[:specimen_id])
    patient = specimen.tests.last.visit.patient
    tracking_number = specimen.tracking_number

    specimen.update_attributes(
        :specimen_status_id => SpecimenStatus.find_by_name("specimen-accepted").id,
        :accepted_by => User.current.id,
        :time_accepted => Time.now
    )

    update_details = {
      tracking_number => tracking_number,
      :status => "specimen_accepted",
      :who_updated => {
        :id =>  User.current.id,
        :first_name => '',
        :last_name => '',
        :phone_number => ''
      }
    }

    if status == true
      NlimsService.update_specimen(update_details)
    else
      order = UnsyncOrder.new
      order.specimen_id = specimen.id
      order.data_not_synced = 'accept specimen'    
      order.data_level = 'specimen'
      order.sync_status = 'not-synced'
      order.updated_by_name = User.current.name
      order.updated_by_id = User.current.id
      order.save
    end

    Sender.send_data(patient, specimen)
    redirect_to request.referrer
  end

  def save_remote
    data = JSON.parse(params[:data])
    identifier = params[:identifier]
    patient = nil

    specimen = Specimen.where(:tracking_number => identifier ).last
    patient = specimen.tests.last.visit.patient rescue nil if !specimen.blank?

    patient = Patient.where(
        :external_patient_number => data['data']['other']['patient']['id']
    ).last if data['data']['other']['patient']['id'].present? and patient.blank?

    if patient.blank?
      patient = Patient.new
      patient.external_patient_number = data['data']['other']['patient']['id']
      patient.name = data['data']['other']['patient']['name']
      patient.dob = data['data']['other']['patient']['dob']
      patient.gender = (data['data']['other']['patient']['gender'].match(/m/i) ? 0 : 1)
      patient.phone_number = ""
      patient.patient_number = (Patient.count + 1) if patient.patient_number.blank?
    end
    patient.save!

   
    if specimen.blank?
      specimen = Specimen.new
      specimen.specimen_type_id = SpecimenType.where(:name => data['data']['other']['sample_type']).last.id
      specimen.accession_number = TestUtils.new_accession_number
      specimen.tracking_number = identifier
      specimen.drawn_by_name = data['data']['other']['sample_created_by']['name']
      specimen.drawn_by_id = data['data']['other']['sample_created_by']['id']
    end

    specimen.specimen_status_id = SpecimenStatus.find_by_name('specimen-accepted').id
    specimen.accepted_by = User.current.id if specimen.accepted_by.blank? || specimen.accepted_by.to_s == '0'
    specimen.priority = data['data']['other']['priority']
    specimen.time_accepted = Time.now 
    specimen.save!

    panel_type = data['data']['tests'].collect{|t| PanelType.find_by_name(t)}.compact.last rescue nil
   

    test_panel = TestPanel.new
    panel = []
    if !panel_type.blank?
      panel = Panel.where(:panel_type_id => panel_type.id).map(&:test_type_id)
      test_panel.panel_type_id = panel_type.id
    end

    (data['data']['tests'].keys || []).each do |name|
     
      name = CGI.unescapeHTML(name)
      type = TestType.find_by_name(name).id rescue next
      test = specimen.tests.where(:test_type_id => type).last
      if test.blank?
        test = Test.new
        test.test_type_id = type
        test.specimen_id = specimen.id
        test.test_status_id = 2
        test.created_by = User.current.id
        test.requested_by = specimen.drawn_by_name
        test.not_done_reasons = " "
        test.person_talked_to_for_not_done = " "

        if !panel_type.blank? and panel.include?(test.test_type_id)
          test_panel.save!
          test.panel_id = test_panel.id
        end
      end

      visit = test.visit
      visit = Visit.new if visit.blank?
      visit.patient_id = patient.id
      visit.visit_type = VisitType.find_by_name('Referral').id if visit.visit_type.blank?
      visit.ward_or_location = 'CWC' if data['data']['other']['order_location'].blank?
      visit.save!

      test.visit_id = visit.id
      test.save

      #Save results
      #tms = data["results"]["#{name}"].keys.last rescue nil
      #(data["results"]["#{name}"][tms]['results'] || []).each do  |measure_name, rst|
      #  measure = Measure.find_by_name(measure_name)
      #  result = TestResult.where(:test_id => test.id, :measure_id => measure.id).first_or_create
      #  result.result = rst
      #  result.save
      #  test.interpretation = data["remarks"]
      #  test.test_status_id = TestStatus.find_by_name('completed').id
      #  test.time_started = data["results"]["#{name}"][tms]['datetime_started']
      #  test.time_completed = data["results"]["#{name}"][tms]['datetime_completed']
      #  test.tested_by = User.first.id if test.tested_by.blank?
      # test.save
      #end rescue nil

    end

    redirect_to "/tests/all?tracking_number=#{specimen.tracking_number}"
  end


  def reject
    @rejection_reasons = RejectionReason.all.map(&:reason)
  end

  def do_reject

    settings = YAML.load_file("#{Rails.root}/config/application.yml")
    nlims = YAML.load_file("#{Rails.root}/config/nlims_connection.yml")  
    status = ApplicationController.up?("#{nlims['nlims_service']}")
   
    specimen = Specimen.find(params[:specimen_id])
    patient = specimen.tests.last.visit.patient

    specimen.update_attributes(
        :specimen_status_id => SpecimenStatus.find_by_name("specimen-rejected").id,
        :rejected_by => User.current.id,
        :rejection_reason_id => RejectionReason.find_by_reason(params[:rejection_reason]).id,
        :reject_explained_to => params[:person_talked_to],
        :time_rejected => Time.now
    )

    update_details = {
      :tracking_number => specimen.tracking_number,
      :status => "specimen_rejected",
      :who_updated => {
        :id =>  User.current.id,
        :first_name => '',
        :last_name => '',
        :phone_number => ''
      }
    }


    if status == true
      res = NlimsService.update_specimen(update_details)  
    else
      order = UnsyncOrder.new
      order.specimen_id = specimen.id
      order.data_not_synced = 'specimen-rejection'    
      order.data_level = 'specimen'
      order.sync_status = 'not-synced'
      order.updated_by_name = User.current.name
      order.updated_by_id = User.current.id
      order.save
    end

    Sender.send_data(patient, specimen)

    redirect_to params[:return_uri]
  end

  def view

  end

  def add_test
    @specimen = Specimen.find(params[:specimen_id])
    already_ordered = @specimen.tests.map(&:name)

    panels = Test.find_by_sql("SELECT * FROM tests WHERE panel_id IS NOT NULL and specimen_id = #{@specimen.id}").map(&:panel_id).uniq rescue []
    panels.each do |p|
      already_ordered << Panel.find(p).panel_type.name rescue (next)
    end

    testtypes = TestType.find_by_sql("SELECT * FROM test_types
                  WHERE orderable_test = 1 AND id IN (SELECT test_type_id FROM testtype_specimentypes WHERE specimen_type_id = #{@specimen.specimen_type_id})")

    tests = []
    paneled_tests = []
    testtypes.each do |type|
      tname = type.name
      tests << tname
      panel = Panel.where(:test_type_id => type.id).last rescue nil
      unless panel.blank?
        pname = panel.panel_type.name
        if !tests.include?(pname)
          tests << pname
        end
        paneled_tests << tname
      end
    end
    @testtypes = (tests - already_ordered - paneled_tests).uniq
  end

  def age(dob)
    now = Time.now.utc.to_date
    now.year - dob.year - ((now.month > dob.month || (now.month == dob.month && now.day >= dob.day)) ? 0 : 1)
  end

  def print_accession_number

    history = (params[:history].blank? ?  "" : params[:history])
    s = TestUtils.create_specimen_label(params[:specimen_id],history)

    send_data(s,
              :type=>"application/label; charset=utf-8",
              :stream=> false,
              :filename=>"#{params[:specimen_id]}-#{rand(10000)}.lbl",
              :disposition => "inline"
    )
  end


  def specimen_barcode
    test = Test.find(params[:test_id])
    print_and_redirect("/test/print_accession_number?specimen_id=#{test.specimen.id}", "/test/details?test_id=#{test.id}")
  end

  def do_add_test
    specimen = Specimen.find(params[:specimen_id])
    visit = Visit.find(specimen.tests.last.visit_id)

      type = TestType.find_by_name(params[:test_type])
      panel_type = PanelType.find_by_name(params[:test_type])

      if !panel_type.blank?
        member_tests = Panel.where(:panel_type_id => panel_type.id)

        test_panel = TestPanel.new
        test_panel.panel_type_id = panel_type.id
        test_panel.save

        (member_tests || []).each do |m_test|
          test = Test.new
          test.visit_id = visit.id
          test.test_type_id = m_test.test_type_id
          test.specimen_id = specimen.id
          test.test_status_id = 2
          test.created_by = User.current.id
          test.panel_id = test_panel.id
          test.requested_by = specimen.tests.last.requested_by
          test.not_done_reasons = ''
          test.person_talked_to_for_not_done = ''
	  test.save
        end
      else
        test = Test.new
        test.visit_id = visit.id
        test.test_type_id = type.id
        test.specimen_id = specimen.id
        test.test_status_id = 2
        test.created_by = User.current.id
        test.requested_by = specimen.tests.last.requested_by
        test.not_done_reasons = ''
        test.person_talked_to_for_not_done = ''
	test.save
      end

    Sender.send_data(visit.patient, specimen)

    redirect_to params[:return_uri]
  end

  def details
    @test = Test.find(params[:test_id])
    @specimen = @test.specimen
    @patient = @test.visit.patient
    @test_name = ""
    if (@test.panel_id.blank?)
      @test_name = @test.test_type.name
    else
      @test_name = TestPanel.find(@test.panel_id).panel_type.name
    end

    render :layout => false
  end

  def clinicians_suggest
    search_string = (params[:search_string] || "").upcase

    search_insert = search_string.blank? ? " " : " AND requested_by REGEXP '#{search_string.strip}' "
    clinicians = Test.find_by_sql("SELECT requested_by, count(*) AS cc
                                      FROM tests
                                        WHERE COALESCE(requested_by, '') != ''  #{search_insert}
                                        GROUP BY requested_by
                                        ORDER BY cc DESC LIMIT 100;").map(&:requested_by)

    render :text => "<li></li><li " + clinicians.map{|clinician| "value=\"#{clinician}\">#{clinician}" }.join("</li><li ") + "</li>"
  end

  private

end
