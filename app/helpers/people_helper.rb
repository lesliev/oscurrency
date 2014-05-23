module PeopleHelper

  def email_help
    t('people.new.never_made_public') + (global_prefs.email_verifications? ? t('people.new.comma_will_be_verified') : '')
  end

  def member_agreement_label
    t('people.new.i_accept_the') + ' ' + link_to(t('people.new.member_agreement'), agreement_path, :target => '_blank', :class => 'small')
  end

  def message_links(people)
    people.map { |p| email_link(p)}
  end

  # Return a person's image link.
  # The default is to display the person's icon linked to the profile.
  def image_link(person, options = {})
    link = options[:link] || person
    image = options[:image] || :icon
    image_options = { :title => h(person.display_name), :alt => h(person.display_name) }
    unless options[:image_options].nil?
      image_options.merge!(options[:image_options])
    end
    link_options =  { :title => h(person.display_name) }
    unless options[:link_options].nil?
      link_options.merge!(options[:link_options])
    end
    content = image_tag(person.send(image), image_options)
    # This is a hack needed for the way the designer handled rastered images
    # (with a 'vcard' class).
    if options[:vcard]
      name = options[:truncate] ? person.display_name.truncate(options[:truncate]) : person.display_name
      content = %(#{content}#{content_tag(:span, h(name),
                                                 :class => "fn" )}).html_safe
    end
    link_to(content, link, link_options)
  end

  # Link to a person (default is by name).
  def person_link(text, person = nil, html_options = nil)
    if person.nil?
      person = text
      text = person.display_name
    elsif person.is_a?(Hash)
      html_options = person
      person = text
      text = person.display_name
    end
    # We normally write link_to(..., person) for brevity, but that breaks
    # activities_helper_spec due to an RSpec bug.
    link_to(h(text), person, html_options)
  end


  def get_admin
    Person.find_first_admin
  end

  def print_fee(fee)
    case(fee.type)
    when("FixedTransactionFee")
      "Fixed transaction fee of #{fee.amount}"
    when("PercentageTransactionFee")
      "Percentage transaction fee of #{fee.percent}%"
    when("RecurringFee")
      "Recurring fee of #{fee.amount} per #{fee.interval}"
    when("FixedTransactionStripeFee")
      "Fixed transaction fee of #{number_to_currency(fee.amount)}"
    when("PercentageTransactionStripeFee")
      "Percentage transaction fee of #{fee.percent}%"
    when("RecurringStripeFee")
      "Recurring fee of #{number_to_currency(fee.amount)} per #{fee.interval}"
    end
  end

  private

    # Make captioned images.
    def captioned(images, captions)
      images.zip(captions).map do |image, caption|
        markaby do
          image << div { caption }
        end
      end
    end
end
