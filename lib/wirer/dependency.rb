# dependency :foo, Class, :features => [:feature, :feature], :optional => true
# dependency :foo, Class, :features => [:feature, :feature], :multiple => true
#
# dependency :foo, Class, :optional => true
# dependency :foo, :feature, :another_feature, :optional => true, :constructor => true

module Wirer

  class Dependency
    def self.new_from_args(*args)
      new(normalise_args(*args))
    end

    def self.new_from_arg_or_args_list(arg_or_args_list)
      new(normalise_arg_or_args_list(arg_or_args_list))
    end

    def self.normalise_arg_or_args_list(arg_or_args_list)
      case arg_or_args_list
      when Hash then arg_or_args_list
      when Array then normalise_args(*arg_or_args_list)
      else normalise_args(arg_or_args_list)
      end
    end

    def self.normalise_args(*args)
      options = args.last.is_a?(Hash) ? args.pop : {}
      args.each do |requirement|
        case requirement
        when Module then options[:class] = requirement
        else (options[:features] ||= []) << requirement
        end
      end
      options
    end

    OPTION_NAMES = [:class, :module, :features, :prefer, :multiple, :optional]

    # By default, dependencies will :prefer => :default.
    # This means if you want to force one factory to be preferred over another
    # in a given situation, you can just add (or wrap it with) a provided feature
    # name of :default.
    PREFER_DEFAULT = :default

    def initialize(options = {})
      required_class = options[:class] || options[:module]
      case required_class
      when Module
        @required_class = required_class
      when String
        @required_class_name = required_class
      when NilClass
        @required_class = nil
      else
        raise ArgumentError, "required :class for a Dependency must be a Module or Class, or a String name of a Module or Class"
      end
      @required_features = options[:features] && [*options[:features]]
      @multiple = options[:multiple] || false
      @optional = options[:optional] || false

      if @multiple
        raise ArgumentError, "preferred features don't make sense for a :multiple depedency" if options.has_key?(:prefer)
      else
        @preferred_features = [*options.fetch(:prefer, PREFER_DEFAULT) || []]
      end
    end

    attr_reader :required_features, :preferred_features
    def multiple?; @multiple; end
    def optional?; @optional; end

    # A string class name may be supplied as the :class arg to the constructor, in which case we only
    # attempt to resolve the actual class from it the first time .required_class is requested.
    #
    # This helps avoid introducing undesired load order dependencies between classes using Wirer::Factory::ClassDSL.
    def required_class
      return @required_class if defined?(@required_class)
      @required_class = @required_class_name.split("::").inject(Object, :const_get)
    end

    def requirements_to_s
      [
        case required_class
        when ::Class then "class #{@required_class}"
        when ::Module then "module #{@required_class}"
        end,
        @required_features && "features #{@required_features.inspect}"
      ].compact.join(" and ")
    end

    def inspect
      description = [
        requirements_to_s,
        ("optional" if @optional),
        ("multiple" if @multiple),
        ("preferring features #{@preferred_features.inspect}" if @preferred_features && !@preferred_features.empty?)
      ].compact.join(', ')
      "#<#{self.class} on #{description}>"
    end

    def match_factories(available_factories)
      candidates = available_factories.select {|f| self === f}
      if !@optional && candidates.length == 0
        raise DependencyFindingError, "No available factories matching #{requirements_to_s}"
      end
      if @multiple
        candidates.map! {|c| yield c} if block_given?; candidates
      else
        candidate = if candidates.length > 1
          if @preferred_features.empty?
            raise DependencyFindingError, "More than one factory available matching #{requirements_to_s}"
          else
            unique_preferred_factory(candidates)
          end
        else
          candidates.first
        end
        block_given? ? yield(candidate) : candidate
      end
    end

    def ===(factory)
      factory.is_a?(Factory::Interface) &&
      (!required_class    || factory.provides_class <= required_class) &&
      (!@required_features || @required_features.all? {|feature| factory.provides_features.include?(feature)})
    end

    def with_options(options)
      new_options = {
        :multiple => @multiple,
        :optional => @optional,
        :class    => required_class,
        :features => @required_features,
        :prefer   => @preferred_features
      }
      new_required_class = options[:class] and begin
        if required_class && !(new_required_class <= required_class)
          raise "Required class #{new_required_class} not compatible with existing requirement for #{required_class}"
        end
        new_options[:class] = new_required_class
      end
      new_required_features = options[:features] and begin
        new_options[:features] ||= []
        new_options[:features] |= [*new_required_features]
      end
      new_preferred_features = options[:prefer] and begin
        new_options[:prefer] ||= []
        new_options[:prefer] |= [*new_preferred_features]
      end
      self.class.new(new_options)
    end

  private

    def unique_preferred_factory(candidates)
      max_preferred_features_count = 0
      winners = []
      candidates.each do |candidate|
        provided = candidate.provides_features
        count = @preferred_features.count {|f| provided.include?(f)}
        if count > max_preferred_features_count
          max_preferred_features_count = count
          winners = [candidate]
        elsif count == max_preferred_features_count
          winners << candidate
        end
      end
      if winners.length > 1
        raise DependencyFindingError,
          "More than one factory available matching #{requirements_to_s}, and tie can't be resolved using preferred_features #{@preferred_features.inspect}"
      end
      winners.first
    end
  end
end
