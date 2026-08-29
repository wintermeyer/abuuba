# A recorder standing in for the Rails routing DSL: evaluates a routes file and
# prints "VERB /path" for every route it declares. Inside a resources block
# every sub-tree nests under the member id, as Rails does.
class Rec
  def initialize; @routes = []; @stack = []; @concerns = {}; @nest = [false]; @with = {}; end
  def run(file); instance_eval(File.read(file), file); self; end
  def routes; @routes.uniq.sort; end
  def cur; "/" + @stack.reject(&:empty?).join("/"); end
  def push(seg); @stack.push(seg.to_s.sub(%r{^/}, "")); end
  def pop; @stack.pop; end
  def add(verb, path)
    rel = @nest.last ? ":id/#{path}" : path.to_s
    p = path.to_s.start_with?("/") ? path.to_s : (cur == "/" ? "/#{rel}" : "#{cur}/#{rel}")
    @routes << [verb, p.gsub(%r{/+}, "/")]
  end
  def enter(seg, nest_inside = false)
    pushed = 0
    if @nest.last then push(":id"); pushed += 1 end
    push(seg); pushed += 1
    @nest.push(nest_inside)
    yield
    @nest.pop
    pushed.times { pop }
  end
  def namespace(name, **o, &b); enter(o[:path] || name) { b&.call }; end
  def scope(*a, **o, &b)
    seg = a.first.is_a?(String) || a.first.is_a?(Symbol) ? a.first.to_s : (o[:path] || "")
    enter(seg) { b&.call }
  end
  def constraints(*a, **o, &b); b&.call; end
  def with_options(**o, &b); saved = @with; @with = saved.merge(o); b&.call; @with = saved; end
  def defaults(*a, **o, &b); b&.call; end
  def concern(name, &b); @concerns[name] = b; end
  def concerns(*names, **o); names.flatten.each { |n| instance_exec(&@concerns[n]) if @concerns[n] }; end
  def member(&b); push(":id"); @nest.push(false); b&.call; @nest.pop; pop; end
  def collection(&b); @nest.push(false); b&.call; @nest.pop; end
  %w[get post put patch delete].each { |v| define_method(v) { |path, **o| add(v.upcase, path) } }
  def match(path, **o); Array(o[:via]).each { |v| add(v.to_s.upcase, path) }; end
  def resources(*names, **o, &b)
    o = @with.merge(o)
    names.each do |n|
      base = (o[:path] || n).to_s
      acts = o[:only] ? Array(o[:only]) : %i[index create show update destroy]
      acts -= Array(o[:except])
      enter("") do
        add("GET", base) if acts.include?(:index)
        add("POST", base) if acts.include?(:create)
        add("GET", "#{base}/:id") if acts.include?(:show)
        (add("PUT", "#{base}/:id"); add("PATCH", "#{base}/:id")) if acts.include?(:update)
        add("DELETE", "#{base}/:id") if acts.include?(:destroy)
        if b || o[:concerns]
          push(base); @nest.push(true)
          concerns(*Array(o[:concerns])) if o[:concerns]
          instance_exec(&b) if b
          @nest.pop; pop
        end
      end
    end
  end
  def resource(*names, **o, &b)
    o = @with.merge(o)
    names.each do |n|
      base = (o[:path] || n).to_s
      acts = o[:only] ? Array(o[:only]) : %i[create show update destroy]
      acts -= Array(o[:except])
      enter("") do
        add("GET", base) if acts.include?(:show)
        add("POST", base) if acts.include?(:create)
        (add("PUT", base); add("PATCH", base)) if acts.include?(:update)
        add("DELETE", base) if acts.include?(:destroy)
        if b then push(base); @nest.push(false); instance_exec(&b); @nest.pop; pop end
      end
    end
  end
  def method_missing(name, *a, **o, &b); b&.call; end
  def respond_to_missing?(*) = true
end
Rec.new.run(ARGV[0]).routes.each { |v, p| puts "#{v} #{p}" }
