require 'sketchup.rb'

module EsimaxTools
  # Deep Select Tool
  class DeepSelectTool
    def initialize
      @cursor_id = UI.create_cursor(File.join(__dir__, 'cursor.png'), 0, 0) rescue nil
      @last_click_time = Time.now
    end

    def activate
      @ip = Sketchup::InputPoint.new
      @drawn = false
    end

    def deactivate(view)
      view.invalidate if @drawn
    end

    def onLButtonDown(flags, x, y, view)
      current_time = Time.now
      is_double_click = (current_time - @last_click_time) < 0.3
      @last_click_time = current_time
      is_shift_pressed = (flags & CONSTRAIN_MODIFIER_MASK) != 0

      ph = view.pick_helper
      ph.do_pick(x, y)
      
      picked = ph.picked_face || ph.picked_edge
      
      if picked
        model = Sketchup.active_model
        model.selection.clear unless is_shift_pressed

        if is_double_click
          if picked.is_a?(Sketchup::Face)
            model.selection.add(picked)
            picked.edges.each { |edge| model.selection.add(edge) }
          elsif picked.is_a?(Sketchup::Edge)
            model.selection.add(picked)
            picked.vertices.each { |vertex| vertex.edges.each { |edge| model.selection.add(edge) } }
          end
        else
          model.selection.add(picked)
        end
      end

      view.invalidate
    end

    def onMouseMove(flags, x, y, view)
      @ip.pick(view, x, y)
      view.invalidate
    end

    def draw(view)
      @ip.draw(view) if @ip.valid?
    end

    def getCursor
      @cursor_id || 0
    end
  end

  # Auto Extrud Tool
  class AutoExtrud
    def self.add_guide_lines(face, entities, guide_heights)
      face_vertices = face.vertices.map(&:position)

      guide_heights.each do |height|
        z_level = height.m
        points = face_vertices.map { |v| [v.x, v.y, z_level] }

        points.each_with_index do |point, index|
          next_point = points[(index + 1) % points.length]
          line = entities.add_line(point, next_point)
          line.material = "red"
        end
      end
    end

    def self.run
      prompts = ["ارتفاع ۱:", "ارتفاع ۲:", "ارتفاع ۳:", "فاصله پوش پول:"]
      defaults = ["0.9", "1.5", "2.4", "2.9"]
      input = UI.inputbox(prompts, defaults, "تنظیم ارتفاع‌های خطوط راهنما و فاصله پوش پول")

      return if input.nil?

      guide_heights = input[0..-2].map(&:to_f)
      push_distance = input[-1].to_f.m

      model = Sketchup.active_model
      entities = model.active_entities
      face = model.selection.grep(Sketchup::Face).first

      unless face
        UI.messagebox("⚠️ لطفاً یک سطح را انتخاب کنید.")
        return
      end

      model.start_operation("Esimax Auto Extrud", true)
      begin
        original_position = face.bounds.center
        face.pushpull(push_distance)

        new_face = entities.grep(Sketchup::Face).find { |f| 
          ((f.bounds.center.z - (original_position.z + push_distance)).abs < 0.01) &&
          ((f.bounds.center - original_position).length < push_distance + 0.1)
        }

        if new_face
          add_guide_lines(new_face, entities, guide_heights)
        else
          puts "❌ چهره جدید پس از پوش پول یافت نشد."
        end
        
        Sketchup.status_text = "✅ خطوط راهنما با موفقیت اضافه شدند!"
        model.commit_operation
      rescue => e
        puts "❌ خطا: #{e.message}"
        model.abort_operation
      end
    end
  end

  # Deep Delete Tool
  class DeepDelete
    def self.delete_selected_entities
      model = Sketchup.active_model
      selection = model.selection
      definitions = model.definitions

      if selection.empty?
        UI.messagebox("لطفاً ابتدا چند شیء انتخاب کنید.")
        return
      end

      model.start_operation('ESIMAX_DeepDelete', true)

      entities_to_remove = selection.to_a
      selection.clear

      def self.process_entity(entity)
        if entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group)
          entity.definition.entities.each { |e| process_entity(e) }
        end
      end

      entities_to_remove.each do |entity|
        process_entity(entity)
        if entity.is_a?(Sketchup::ComponentInstance) && entity.valid?
          definition = entity.definition
          entity.erase! if entity.valid?
          definitions.remove(definition) if definition.instances.empty?
        else
          entity.erase! if entity.valid?
        end
      end

      model.commit_operation
    end
  end

  # Purge Tool
  class Purge
    @active = false
    @current_step = 0
    @progress = 0
    @step_increments = [40, 30, 20, 10]

    def self.start_step_purge
      return if @active
      
      @active = true
      @current_step = 0
      @progress = 0
      model = Sketchup.active_model
      
      Sketchup.status_text = "آماده‌سازی پاکسازی... (0%)"
      
      @purge_steps = [
        ["پاکسازی کامپوننت‌ها", -> { model.definitions.purge_unused }],
        ["پاکسازی متریال‌ها", -> { model.materials.purge_unused }],
        ["پاکسازی لایه‌ها", -> { model.layers.purge_unused }],
        ["پاکسازی تصاویر", -> { model.active_entities.grep(Sketchup::Image) { |img| img.erase! if img.deleted? } }]
      ]
      
      execute_next_step(model)
    end

    def self.execute_next_step(model)
      return unless @active
      
      if @current_step < @purge_steps.size
        name, action = @purge_steps[@current_step]
        target_percent = @progress + @step_increments[@current_step]
        
        Sketchup.status_text = "شروع #{name}... (#{@progress}%)"
        
        model.start_operation(name, true)
        UI.start_timer(0, false) {
          begin
            action.call
            model.commit_operation
            
            @progress = target_percent
            @current_step += 1
            Sketchup.status_text = "اتمام #{name} (#{@progress}%)"
            
            UI.start_timer(0.5, false) { execute_next_step(model) }
          rescue => e
            model.abort_operation
            Sketchup.status_text = "خطا در #{name}!"
            @active = false
          end
        }
      else
        @active = false
        Sketchup.status_text = "پاکسازی کامل شد! (100%)"
        UI.beep if UI.respond_to?(:beep)
      end
    end
  end

  # Random Color Tool
  class RandomColor
    def self.apply_random_color
      model = Sketchup.active_model
      selection = model.selection

      color = Sketchup::Color.new(rand(256), rand(256), rand(256))
      mat_name = "RandomColor_#{Time.now.to_i}"
      material = model.materials.add(mat_name)
      material.color = color

      model.materials.current = material

      model.start_operation("Apply Random Color", true)
      selection.grep(Sketchup::Face) { |face| face.material = material }
      model.commit_operation
    end
  end

  # Texture Rotate Tool
  class TextureRotate
    class Tool
      def initialize
        @msg = "← چرخش پادساعتگرد | → چرخش ساعتگرد | ↓ زاویه دلخواه | ↑ تراز با لبه | کلیک برای حذف متریال"
        @angle = 45.0
        Sketchup.active_model.selection.clear
      end

      def activate
        update_ui
      end

      def enableVCB?
        true
      end

      def onUserText(text, view)
        @angle = text.to_f
        update_ui
        view.invalidate
      end

      def update_ui
        Sketchup.set_status_text(@msg)
        Sketchup.vcb_label = 'زاویه:'
        Sketchup.vcb_value = @angle
      end

      def onMouseMove(flags, x, y, view)
        ip = view.inputpoint(x, y)
        if @picked_face != ip.face
          @picked_face = ip.face
        end
        view.invalidate
      end

      def draw(view)
        return unless @picked_face
        view.drawing_color = "orange"
        view.line_width = 3
        view.draw(GL_LINE_LOOP, @picked_face.vertices.map(&:position))
      end

      def rotate_texture(angle = nil)
        return unless @picked_face

        angle ||= @angle
        model = Sketchup.active_model
        model.start_operation "Rotate Texture", true

        tw = Sketchup.create_texture_writer
        uvh = @picked_face.get_UVHelper(true, false, tw)
        trans = Geom::Transformation.rotation(@picked_face.bounds.center, @picked_face.normal, angle.degrees)

        point_pairs = @picked_face.outer_loop.vertices.first(2).flat_map do |v|
          [v.position.transform(trans), uvh.get_front_UVQ(v.position)]
        end

        @picked_face.position_material(@picked_face.material, point_pairs, true)
        model.commit_operation
      end

      def align_texture
        return unless @picked_face && @picked_face.material&.texture

        model = Sketchup.active_model
        model.start_operation "Align Texture", true

        edge = @picked_face.edges.find { |e| !@picked_face.normal.parallel?(e.line[1]) }
        return unless edge

        anchor = edge.start.position
        vector = edge.line[1]
        texture_width = @picked_face.material.texture.width
        vector.length = texture_width

        points = [anchor, [0, 0, 0], anchor.offset(vector), [1, 0, 0]]
        @picked_face.position_material(@picked_face.material, points, true)

        model.commit_operation
      end

      def onKeyDown(key, repeat, flags, view)
        return unless repeat == 1
        case key
        when VK_LEFT  then rotate_texture(90)
        when VK_RIGHT then rotate_texture(-90)
        when VK_DOWN  then rotate_texture
        when VK_UP    then align_texture
        end
      end

      def onLButtonDown(flags, x, y, view)
        @picked_face.material = nil if @picked_face
      end
    end
  end

  # Deep Unique Tool
  module DeepUnique
    def self.make_all_nested_components_unique
      model = Sketchup.active_model
      model.start_operation("Esimax_Deep Unique", true)

      defs_made_unique = {}

      traverse_and_make_unique(model.entities, defs_made_unique)

      model.commit_operation
      Sketchup.status_text = "✅ کامپوننت‌های انتخاب‌شده با موفقیت یونیک شدند!"
    end

    def self.traverse_and_make_unique(entities, defs_made_unique)
      entities.grep(Sketchup::ComponentInstance).each do |comp|
        comp_def = comp.definition

        unless defs_made_unique[comp_def]
          comp.make_unique
          defs_made_unique[comp.definition] = true
        end

        traverse_and_make_unique(comp.definition.entities, defs_made_unique)
      end
    end
  end

  # Save Components Tool
  class SaveComponents
    def self.save_selected_components
      model = Sketchup.active_model
      selection = model.selection

      if selection.empty?
        UI.messagebox("لطفاً حداقل یک کامپوننت یا گروه انتخاب کنید.")
        return
      end

      entities = selection.to_a.select { |entity| entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group) }
      if entities.empty?
        UI.messagebox("لطفاً فقط کامپوننت‌ها یا گروه‌ها را انتخاب کنید.")
        return
      end

      folder_path = UI.select_directory(title: "انتخاب پوشه برای ذخیره کامپوننت‌ها")
      unless folder_path && File.directory?(folder_path) && File.writable?(folder_path)
        UI.messagebox("⚠️ پوشه نامعتبر است یا دسترسی نوشتن ندارد.")
        return
      end

      model.start_operation("Esimax Save Components", true)
      saved_count = 0

      entities.each_with_index do |entity, index|
        begin
          entity_name = if entity.is_a?(Sketchup::ComponentInstance)
                          entity.definition.name
                        elsif entity.is_a?(Sketchup::Group)
                          entity.name
                        end

          entity_name = entity_name.gsub(/[<>:"\/\\|?*]/, '_')
          entity_name = "Component_#{index + 1}" if entity_name.empty? || entity_name == "#"

          component_definition = if entity.is_a?(Sketchup::ComponentInstance)
                                  entity.definition
                                elsif entity.is_a?(Sketchup::Group)
                                  component = entity.to_component
                                  component.definition
                                end

          # Copy used materials to the component definition
          used_materials = []
          component_definition.entities.grep(Sketchup::Face) do |face|
            used_materials << face.material if face.material
            used_materials << face.back_material if face.back_material
          end
          used_materials.uniq.each do |mat|
            next unless mat
            component_definition.model.materials.add(mat.name) rescue nil
          end

          file_name = "#{entity_name}.skp"
          file_path = File.join(folder_path, file_name)

          puts "📝 تلاش برای ذخیره: #{file_path}"
          success = component_definition.save_as(file_path)

          if success && File.exist?(file_path)
            puts "✅ ذخیره شد: #{file_path} (اندازه: #{File.size(file_path)} بایت)"
            saved_count += 1
          else
            puts "❌ خطا در ذخیره #{entity_name}: فایل ذخیره نشد."
          end

          # Clean up temporary component if it was a group
          if entity.is_a?(Sketchup::Group) && component && component.valid?
            component.erase! rescue nil
          end
        rescue => e
          puts "❌ خطا در ذخیره کامپوننت/گروه #{entity_name}: #{e.message}"
        end
      end

      model.commit_operation
      if saved_count > 0
        Sketchup.status_text = "✅ #{saved_count} کامپوننت/گروه با موفقیت ذخیره شد!"
        UI.messagebox("#{saved_count} کامپوننت/گروه با موفقیت در #{folder_path} ذخیره شدند.")
      else
        Sketchup.status_text = "❌ هیچ کامپوننت/گروهی ذخیره نشد."
        UI.messagebox("❌ هیچ فایلی ذخیره نشد. لطفاً لاگ کنسول را بررسی کنید.")
      end
    end
  end

  # Capture Screenshot Tool
  class CaptureScreenshot
    def self.capture
      model = Sketchup.active_model
      view = model.active_view
      model_path = model.path

      if model_path.empty?
        UI.messagebox("ابتدا فایل SketchUp را ذخیره کنید.")
        return
      end

      folder = File.dirname(model_path)
      unless File.directory?(folder) && File.writable?(folder)
        UI.messagebox("⚠️ پوشه مدل غیرقابل دسترسی است یا اجازه نوشتن ندارد.")
        return
      end

      basename = File.basename(model_path, '.skp')
      timestamp = Time.now.strftime('%Y-%m-%d_%H-%M-%S')
      output_path = File.join(folder, "#{basename}_#{timestamp}.jpg")

      puts "📸 تلاش برای ذخیره اسکرین‌شات: #{output_path}"

      model.start_operation("Esimax Capture Screenshot", true)
      begin
        success = view.write_image({
          :filename    => output_path,
          :width       => 1920,
          :height      => 1080,
          :antialias   => false,
          :compression => 0.90,
          :show_ui     => false
        })

        if success && File.exist?(output_path)
          puts "✅ اسکرین‌شات ذخیره شد: #{output_path} (اندازه: #{File.size(output_path)} بایت)"
          Sketchup.status_text = "✅ اسکرین‌شات ذخیره شد!"
          UI.messagebox("عکس ذخیره شد:\n#{output_path}")
        else
          puts "❌ خطا در ذخیره اسکرین‌شات: فایل ذخیره نشد."
          UI.messagebox("❌ خطا در ذخیره اسکرین‌شات. لطفاً لاگ کنسول را بررسی کنید.")
        end

        model.commit_operation
      rescue => e
        model.abort_operation
        puts "❌ خطا در ذخیره اسکرین‌شات: #{e.message}"
        UI.messagebox("❌ خطا: #{e.message}")
      end
    end
  end

  unless file_loaded?(__FILE__)
    extensions_menu = UI.menu('Extensions')
    esimax_menu = extensions_menu.add_submenu('EsimaxTools')
    
    esimax_menu.add_item('Deep Select Tool') { Sketchup.active_model.select_tool(DeepSelectTool.new) }
    esimax_menu.add_item('Auto Extrud') { AutoExtrud.run }
    esimax_menu.add_item('Deep Delete') { DeepDelete.delete_selected_entities }
    esimax_menu.add_item('Purge') { Purge.start_step_purge }
    esimax_menu.add_item('Random Color') { RandomColor.apply_random_color }
    esimax_menu.add_item('Texture Rotate') { Sketchup.active_model.select_tool(TextureRotate::Tool.new) }
    esimax_menu.add_item('Deep Unique') { DeepUnique.make_all_nested_components_unique }
    esimax_menu.add_item('Save Components') { SaveComponents.save_selected_components }
    esimax_menu.add_item('Capture Screenshot') { CaptureScreenshot.capture }

    UI.add_context_menu_handler do |menu|
      selection = Sketchup.active_model.selection
      if selection.grep(Sketchup::Face).any?
        menu.add_item("Esimax Auto Extrud") { AutoExtrud.run }
      end
      if selection.any? { |entity| entity.is_a?(Sketchup::ComponentInstance) || entity.is_a?(Sketchup::Group) }
        menu.add_item("🗑 Esimax Deep Delete") { DeepDelete.delete_selected_entities }
        menu.add_item("Esimax Save Components") { SaveComponents.save_selected_components }
      end
      if selection.grep(Sketchup::ComponentInstance).any?
        menu.add_item("Esimax Deep Unique") { DeepUnique.make_all_nested_components_unique }
      end
    end
    
    file_loaded(__FILE__)
  end
end