# == Schema Information
#
# Table name: exchanges
#
#  id            :integer          not null, primary key
#  customer_id   :integer
#  worker_id     :integer
#  amount        :decimal(8, 2)    default(0.0)
#  created_at    :datetime
#  updated_at    :datetime
#  group_id      :integer
#  metadata_id   :integer
#  metadata_type :string(255)
#  deleted_at    :time
#  notes         :string(255)
#  wave_all_fees :boolean          default(FALSE)
#

class Exchange < ActiveRecord::Base
  include ActivityLogger
  include ActionView::Helpers::NumberHelper
  acts_as_paranoid

  attr_accessor  :offer_count

  belongs_to :customer, :class_name => "Person", :foreign_key => "customer_id"
  belongs_to :worker, :class_name => "Person", :foreign_key => "worker_id"
  belongs_to :metadata, :polymorphic => :true
  belongs_to :group

  validates_presence_of :customer, :worker, :amount, :metadata
  validates_presence_of :group_id
  validate :offer_exists
  validate :group_has_a_currency_and_includes_both_counterparties_as_members
  validate :amount_is_positive
  validate :worker_is_not_customer
  validate :customer_has_sufficient_balance

  attr_accessible :amount, :group_id

  attr_accessible :customer_id
  attr_accessible *attribute_names, :as => :admin
  attr_readonly :amount
  attr_readonly :customer_id, :worker_id, :group_id

  # These two callbacks are a bit of a hack to allow
  # admins to create Exchanges via Rails Admin. Used
  # to create a no-bid request.
  before_validation :check_metadata
  before_create :save_metadata

  after_create :log_activity
  after_create :decrement_offer_available_count
  before_create :calculate_account_balances
  after_create :send_payment_notification_to_worker
  after_create :send_fee_notification_to_worker
  before_destroy :delete_calculate_account_balances

  scope :by_customer, ->(person_id) { where(customer_id: person_id) }
  scope :everyone, :conditions => {}
  scope :everyone_by_group, ->(group_id) { where(group_id: group_id) }
  scope :by_time, lambda { |time_start, time_end|
    where('created_at BETWEEN ? AND ?', time_start, time_end + 1.day)
  }
  scope :by_month, ->(date) { where("DATE_TRUNC('month',created_at) = ?", date) }
  scope :by_year, ->(date) { where("DATE_TRUNC('year', created_at) = ?", date) }

  def log_activity
    unless self.group.private_txns?
      add_activities(:item => self, :person => self.worker, :group => self.group)
    end
  end

  # memo is a method for displaying a transaction's note in the admin interface
  # previously, a txn created by an admin set metadata.name to 'admin transfer'.
  # this is no longer the case as such txns copy self.notes to metadata.name.
  def memo
    metadata.name == 'admin transfer' ? self.notes : metadata.name
  end

  # For the cases when the metadata for an Exchange is itself an Exchange,
  # it is necessar for an Exchange to respond to the 'name' method as an
  # Offer or Req does. Amy suggested that the name of the recipient in the
  # exchange would be the best value to use, so this method supports that.
  # NOTE that this should be optimized so that the worker (Person) data is
  # not lazily-loaded.
  def name
    worker.display_name if worker
  end

  def self.total_on(date)
    Exchange.sum(:amount, :conditions => ["date(created_at) = ?", date])
  end

  # XXX person_id hacks for cancan's load_and_authorize_resource
  def person_id
    self.worker_id
  end

  def person_id=(worker_id)
    self.worker_id = worker_id
  end

  def self.total_on_month(date)
    Exchange.sum(:amount, :conditions => ["DATE_TRUNC('month',created_at) = ?", date])
  end

  def group_id_enum
    Group.where(adhoc_currency:true).map {|g| [g.unit,g.id]}
  end

  def send_fee_notification_to_worker
    if self.notes && self.notes.include?("fee")
      exchange_note = Message.new(:talkable_id => self.metadata.id, :talkable_type => self.metadata.class.to_s)
      subject = I18n.translate('exchanges.notify.you_have_been_billed_a_fee')
      exchange_note.subject =  subject.mb_chars.length > 75 ? subject.mb_chars.slice(0,75).concat("...") : subject
      exchange_note.content =  self.notes + ": " + nice_decimal(self.amount) + " " +  self.group.unit
      exchange_note.sender = Person.find_by_name("admin")
      exchange_note.recipient = self.worker
      exchange_note.exchange = self
      exchange_note.save!
    end
  end

  private

  # Hack to create a new Request when Exchanges are
  # created via RailsAdmin. We are just assuming that
  # if the metadata is nil, it must be an admin request.
  # Cancan will still ensure proper authorization.
  def check_metadata
    unless self.metadata
      req = Req.new
      req.name = self.notes.presence || 'admin transfer'
      req.estimated_hours = self.amount
      req.due_date = Time.now
      req.person = self.customer
      req.biddable = false
      req.group = self.group
      self.metadata = req
    end
  end

  # If the metadata associated with this request is new,
  # save it before saving the exchange.
  def save_metadata
    self.metadata.save! if self.metadata.new_record?
  end

  def amount_is_positive
    unless amount > 0
      errors.add(:amount, "must be greater than zero")
    end
  end

  def worker_is_not_customer
    if customer && worker && customer == worker
      errors.add(:worker, "cannot be not be the payer")
    end
  end

  def group_has_a_currency_and_includes_both_counterparties_as_members
    if customer && worker && group
      unless worker.groups.include?(self.group)
        errors.add(:group_id, "does not include recipient as a member")
      end
      unless customer.groups.include?(self.group)
        errors.add(:group_id, "does not include payer as a member")
      end
      unless self.group.adhoc_currency?
        errors.add(:group_id, "does not have its own currency")
      end
    end
  end

  def offer_exists
    if self.new_record?
      if self.metadata.class == Offer
        if self.metadata.available_count == 0
          errors.add(:base, 'This offer is no longer available')
        end
      end
    end
  end

  def customer_has_sufficient_balance
    if customer && group
      account = customer.account(group)
      if account && account.credit_limit
        if account.available_balance < amount
          errors.add(:customer, 'Customer has insufficient balance')
        end
      end
    end
  end

  def decrement_offer_available_count
    if self.metadata.class == Offer
      self.metadata.available_count -= self.offer_count || 1
      self.metadata.save
    end
  end

  def calculate_account_balances
    begin
      Account.transaction do
        if group.nil?
          # this should not happen anymore
          raise "no group specified"
        else
          worker.account(group).deposit(amount)
          customer.account(group).withdraw(amount)
        end
      end
    rescue => e
      raise e.to_s
      false
    end
  end

  def delete_calculate_account_balances
    begin
      Account.transaction do
        if group.nil?
          raise "no group specified"
        else
          worker.account(group).withdraw_and_decrement_earned(amount)
          customer.account(group).deposit_and_decrement_paid(amount)
          if self.metadata.class == Req
            unless self.metadata.biddable?
              self.metadata.destroy
            end
          end
        end
      end
    rescue => e
      raise e.to_s
    end
    send_suspend_payment_notification_to_worker
  end

  def send_payment_notification_to_worker
    unless self.notes && self.notes.include?("fee")
      form = SystemMessageTemplate.with_type_and_language('send_payment_notyfication', I18n.locale.to_s)
      exchange_note = Message.new(:talkable_id => self.metadata.id, :talkable_type => self.metadata.class.to_s)
      subject = form.payment_notification_subject(nice_decimal(self.amount), self.group.unit, self.metadata.name)
      exchange_note.subject =  subject.mb_chars.length > 75 ? subject.mb_chars.slice(0,75).concat("...") : subject
      exchange_note.content = form.payment_notification_text(self.customer.name, nice_decimal(self.amount), self.group.unit)
      exchange_note.sender = self.customer
      exchange_note.recipient = self.worker
      exchange_note.exchange = self
      exchange_note.save!
    end
  end

  def send_suspend_payment_notification_to_worker
    # form = SystemMessageTemplate.with_type_and_language('send_suspend_payment_notyfication', I18n.locale.to_s)
    # exchange_note = Message.new()
    # name = self.metadata.name if self.metadata.class.method_defined?(:name) # if metadata is exchange, then there is no name
    # subject = form.payment_notification_subject(nice_decimal(self.amount), self.group.unit, name)
    # exchange_note.subject =  subject.mb_chars.length > 75 ? subject.mb_chars.slice(0,75).concat("...") : subject
    # exchange_note.content = form.payment_notification_text(self.customer.name, nice_decimal(self.amount), self.group.unit)

    # exchange_note.sender = self.customer
    # exchange_note.recipient = self.worker
    # exchange_note.save!
  end

  def nice_decimal(decimal)
    number_with_precision(decimal, precision: 2)
  end
end
