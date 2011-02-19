class RbVmomi::VIM::ServiceInstance
  def find_datacenter path=nil
    if path
      content.rootFolder.traverse path, VIM::Datacenter
    else
      content.rootFolder.childEntity.grep(VIM::Datacenter).first
    end
  end

  def wait_for_multiple_tasks interested, tasks
    version = ''
    interested = (interested + ['info.state']).uniq
    task_props = Hash.new { |h,k| h[k] = {} }

    filter = @soap.propertyCollector.CreateFilter :spec => {
      :propSet => [{ :type => 'Task', :all => false, :pathSet => interested }],
      :objectSet => tasks.map { |x| { :obj => x } },
    }, :partialUpdates => false

    begin
      until task_props.size == tasks.size and task_props.all? { |k,h| %w(success error).member? h['info.state'] }
        result = @soap.propertyCollector.WaitForUpdates(version: version)
        version = result.version
        os = result.filterSet[0].objectSet

        os.each do |o|
          changes = Hash[o.changeSet.map { |x| [x.name, x.val] }]

          interested.each do |k|
            task = tasks.find { |x| x._ref == o.obj._ref }
            task_props[task][k] = changes[k] if changes.member? k
          end
        end

        yield task_props
      end
    ensure
      @soap.propertyCollector.CancelWaitForUpdates
      filter.DestroyPropertyFilter
    end
  end
end
