# == Schema Information
#
# Table name: memberships
#
#  id          :integer          not null, primary key
#  group_id    :integer
#  person_id   :integer
#  status      :integer
#  accepted_at :datetime
#  created_at  :datetime
#  updated_at  :datetime
#  roles_mask  :integer
#

require 'will_paginate/array'

class Membership < ActiveRecord::Base
  extend ActivityLogger
  extend PreferencesHelper

  scope :with_role, ->(role) { where('roles_mask & ? > 0', 2**ROLES.index(role.to_s)) }
  scope :active, -> { includes(:person).where(people: { deactivated: false }) }
  scope :visible, -> { includes(:person).where(people: { visible: true }) }
  scope :listening, lambda {
    active.includes(:member_preference)
          .where(member_preferences: { forum_notifications: true })
  }

  belongs_to :group
  belongs_to :person
  has_one :member_preference
  has_many :activities, :as => :item #, :dependent => :destroy

  validates_presence_of :person_id, :group_id
  before_create :add_default_roles
  after_create :create_member_preference

  # Status codes.
  ACCEPTED  = 0
  INVITED   = 1 # deprecated
  PENDING   = 2

  ROLES = %w[individual admin moderator org point_of_sale_operator]
  EXCLUDE_ROLES = %w[individual moderator org] # reserved for future use

  class << self
    def search_by(text)
      includes(:person).where(Person.arel_table[:name].matches("%#{text}%").or(Person.arel_table[:business_name].matches("%#{text}%")).or(Person.arel_table[:description].matches("%#{text}%")))
    end

    # For issue #272, people should be ordered by display name(display_name in person.rb) which is business_name or name
    # The following sql is for getting business_name + name
    # case when people.business_name is null then '' else people.business_name end) || people.name
    def custom_search(category,group,page,posts_per_page,search=nil)
      unless category
        group
          .memberships
          .visible
          .active
          .search_by(search)
          .paginate(
            page: page,
            conditions: [ 'status = ?', Membership::ACCEPTED ],
            order: "lower((case when people.business_name is null then '' else people.business_name end) || people.name) ASC",
            include: :person,
            per_page: posts_per_page
          )
      else
        category.people.all(
          joins: :memberships,
          select: "people.*,memberships.id as categorized_membership",
          conditions: {
            memberships: {
              group_id: group.id
            },
            people: {
              deactivated: false,
              visible: true,
            }
          },
          order: "lower((case when people.business_name is null then '' else people.business_name end) || people.name) ASC"
        ).map do |p|
          Membership.find(p.categorized_membership)
        end.paginate(
          page: page,
          conditions: [ 'status = ?', Membership::ACCEPTED ],
          include: :person,
          per_page: posts_per_page
        )
      end
    end
  end

  def account
    group.adhoc_currency? ? person.account(group) : nil
  end

  def add_default_roles
    group.default_roles.each do |default_role|
      self.add_role(default_role)
    end
  end

  def create_member_preference
    MemberPreference.create(:membership => self)
  end

  # Accept a membership request (instance method).
  def accept
    Membership.accept(person, group)
  end

  def breakup
    Membership.breakup(person, group)
  end

  def roles=(roles)
    self.roles_mask = (roles & ROLES).map { |r| 2**ROLES.index(r) }.sum
  end

  def add_role(new_role)
    a = self.roles
    a << new_role
    self.roles = a
  end

  def roles
    ROLES.reject do |r|
      ((roles_mask || 0) & 2**ROLES.index(r)).zero?
    end
  end

  def is?(role)
    roles.include?(role.to_s)
  end

  class << self

    # Return true if the person is member of the group.
    def exist?(person, group)
      where(:person_id => person, :group_id => group).exists?
    end

    # Make a pending membership request.
    def request(person, group, send_mail = nil)
      # do not ignore false value for send_mail
      send_mail = global_prefs.email_notifications? if send_mail.nil?
      unless person.groups.include?(group) or Membership.exist?(person, group)
        if group.public? or group.private?
          membership = nil
          transaction do
            membership = create(:person => person, :group => group, :status => PENDING)
            after_transaction { PersonMailerQueue.membership_request(membership) } if send_mail
          end
          if group.public?
            Membership.accept(person, group)
            after_transaction { PersonMailerQueue.membership_public_group(membership) } if send_mail
          end
        end
        true
      end
    end

    def invite(person, group, send_mail = nil)
      if send_mail.nil?
        send_mail = global_prefs.email_notifications?
      end
      if Membership.exist?(person, group)
        nil
      else
        transaction do
          invitation = Invitation.create(person: person, group: group)
          if send_mail
            after_transaction { PersonMailerQueue.invitation_notification(invitation) }
          end
        end
        true
      end
    end

    # Accept a membership request.
    def accept(person, group)
      transaction do
        accepted_at = Time.now
        accept_one_side(person, group, accepted_at)
      end
      log_activity(mem(person, group))
    end

    def breakup(person, group)
      transaction do
        destroy(mem(person, group))
      end
    end

    def mem(person, group)
      where(:person_id => person, :group_id => group).first
    end

    def accepted?(person, group)
      where(:person_id => person, :group_id => group, :status => ACCEPTED).exists?
    end

    def pending?(person, group)
      where(:person_id => person, :group_id => group, :status => PENDING).exists?
    end

    # private

    # Update the db with one side of an accepted connection request.
    def accept_one_side(person, group, accepted_at)
      mem = mem(person, group)
      mem.status = ACCEPTED
      mem.accepted_at = accepted_at
      mem.add_role('individual')
      mem.save

      return if person.accounts.exists?(group_id: group.id)

      account = Account.new(name: group.name) # group name can change
      account.balance = Account::INITIAL_BALANCE
      account.person = person
      account.group = group
      account.credit_limit = group.default_credit_limit
      account.save
    end

    def log_activity(membership)
      activity = Activity.create!(:item => membership, :person => membership.person)
      add_activities(:activity => activity, :person => membership.person)
    end
  end
end
