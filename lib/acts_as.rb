require "acts_as/version"

module ActsAs
  class ActsAs::ActiveRecordOnly < StandardError; end

  PREFIX = %w(id created_at updated_at)

  def self.included(base)
    raise ActiveRecordOnly unless base < ActiveRecord::Base
    base.extend ClassMethods
  end

  def previous_changes
    self.class.acts_as_fields.keys.map{ |association| send(association).previous_changes }
      .reduce(super) do |current, association_changes|
        current.merge(association_changes)
      end
  end

  def update_column(name, value)
    association = self.class.acts_as_fields.detect { |k,v| v.values.flatten.include?(name.to_s) }.try(:first)

    if association.present?
      if self.class.acts_as_fields[association][:prefix].include?(name.to_s)
        name.gsub!(/#{Regexp.quote(association)}_/, '')
      end
      send(association).update_column name, value
    else
      super
    end
  end

  def acts_as_field_match?(method)
    @association_match = self.class.acts_as_fields_match(method)
    @association_match && send(@association_match).respond_to?(method)
  end

  module ClassMethods
    def acts_as(association, with: [], prefix: [], **options)
      belongs_to(association, **options.merge(autosave: true))

      define_method(association) do |*args|
        acted = super(*args) || send("build_#{association}", *args)
        acted.save if persisted? && acted.new_record?
        acted
      end

      if (association_class = (options[:class_name] || association).to_s.camelcase.constantize).table_exists?
        whitelist_and_delegate_fields(association_class, association, prefix, with)
      end
    end

    def acts_as_fields
      @acts_as_fields ||= {}
    end

    def acts_as_fields_match(method)
      acts_as_fields.select do |association, types|
        types.values.flatten.select { |f| method.to_s.include?(f) }.any?
      end.keys.first
    end

    def where(opts = :chain, *rest)
      return self if opts.blank?
      relation = super
      #TODO support nested attribute joins like Guns.where(rebels: {strength: 10}))
      # for now, only first level joins will happen automagically
      if opts.is_a? Hash
        detected_associations = opts.keys.map {|attr| acts_as_fields_match(attr) }
                                         .reject {|attr| attr.nil?}
        return relation.joins(detected_associations) if detected_associations.any?
      end
      relation
    end

    def expand_hash_conditions_for_aggregates(attrs)
      attrs = super(attrs)
      expanded_attrs = {}

      attrs.each do |attr, value|
        if (association = acts_as_fields_match(attr)) && !self.columns.map(&:name).include?(attr.to_s)
          expanded_attrs[new.send(association).class.table_name] = { attr => value }
        else
          expanded_attrs[attr] = value
        end
      end
      expanded_attrs
    end

    private

    def whitelist_and_delegate_fields(association_class, one_association, prefix, with)
      prefix    = delegations(association_class, prefix)
      no_prefix = delegations(association_class, with)

      delegate(*(prefix),     to: one_association, prefix: true)
      delegate(*(no_prefix),  to: one_association)

      acts_as_fields[one_association] = {
        no_prefix:  no_prefix,
        prefix:     prefix.map { |field| "#{one_association}_#{field}" }
      }
    end

    def boolean_columns(association_class)
      association_class.columns.select{ |column| column.sql_type == 'boolean' }.map(&:name)
    end

    def delegations(association_class, delegated_names)
      delegated_bools      = boolean_columns(association_class)  & delegated_names
      delegated_columns    = association_class.column_names      & delegated_names
      delegated_methods    = delegated_names - delegated_bools - delegated_columns
      delegated_bools      = delegated_bools    + delegated_bools.map     { |field| "#{field}?" }
      delegated_columns    = delegated_columns  + delegated_columns.map   { |field| "#{field}=" } + delegated_columns.map  { |field| "#{field}_was" }

      delegated_bools + delegated_methods + delegated_columns
    end
  end
end
