const std = @import("std");
const win = std.os.windows;

const c = @cImport({
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", {});
    @cInclude("vulkan/vulkan.h");
});

const QueueFamilyIndices = struct {
    graphics_family: ?u32,
    present_family: ?u32,

    pub fn same(self: QueueFamilyIndices) bool {
        return self.graphics_family.? == self.present_family.?;
    }

    pub fn to_array(self: QueueFamilyIndices) [2]u32 {
        return .{ self.graphics_family.?, self.present_family.? };
    }
};

test "QueueFamilyIndices methods" {
    var queue_family_indices: QueueFamilyIndices = .{
        .graphics_family = 1,
        .present_family = 1,
    };
    try std.testing.expect(queue_family_indices.same());

    indices.present_family = 2;
    try std.testing.expect(!queue_family_indices.same());

    try std.testing.expectEqual(queue_family_indices.to_array(), [_]u32{ 1, 2 });
}

const SwapChainSupportDetails = struct {
    capabilities: c.VkSurfaceCapabilitiesKHR,
    formats: []c.VkSurfaceFormatKHR,
    present_modes: []c.VkPresentModeKHR,
};

const Vertex = struct {
    pos: [2]f32,
    color: [3]f32,

    pub fn getBindingDescription() c.VkVertexInputBindingDescription {
        const binding_description = c.VkVertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(Vertex),
            .inputRate = c.VK_VERTEX_INPUT_RATE_VERTEX,
        };

        return binding_description;
    }

    pub fn getAttributeDescriptions() [2]c.VkVertexInputAttributeDescription {
        const attribute_descriptions = [2]c.VkVertexInputAttributeDescription{
            .{
                .binding = 0,
                .location = 0,
                .format = c.VK_FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex, "pos"),
            },
            .{
                .binding = 0,
                .location = 1,
                .format = c.VK_FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex, "color"),
            },
        };

        return attribute_descriptions;
    }
};

const Mat4 = [4][4]f32;

const UniformBufferObject = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

const required_device_extensions = [_][]const u8{c.VK_KHR_SWAPCHAIN_EXTENSION_NAME};
const width = 640;
const height = 360;
const max_frames_in_flight: u8 = 2;

var start_time: i64 = undefined;

const vertices = [_]Vertex{
    .{ .pos = .{ -0.5, -0.5 }, .color = .{ 1.0, 0.0, 0.0 } },
    .{ .pos = .{ 0.5, -0.5 }, .color = .{ 0.0, 1.0, 0.0 } },
    .{ .pos = .{ 0.5, 0.5 }, .color = .{ 0.0, 0.0, 1.0 } },
    .{ .pos = .{ -0.5, 0.5 }, .color = .{ 1.0, 1.0, 1.0 } },
};
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

var current_frame: u32 = 0;

instance: c.VkInstance,
surface: c.VkSurfaceKHR,
physical_device: c.VkPhysicalDevice,
device: c.VkDevice,
graphics_queue: c.VkQueue,
present_queue: c.VkQueue,
swapchain: c.VkSwapchainKHR,
swapchain_image_format: c.VkFormat,
swapchain_extent: c.VkExtent2D,
swapchain_images: []c.VkImage,
swapchain_image_views: []c.VkImageView,
swapchain_framebuffers: []c.VkFramebuffer,
render_pass: c.VkRenderPass,
descriptor_set_layout: c.VkDescriptorSetLayout,
pipeline_layout: c.VkPipelineLayout,
pipeline: c.VkPipeline,
command_pool: c.VkCommandPool,
vertex_buffer: c.VkBuffer,
vertex_buffer_memory: c.VkDeviceMemory,
index_buffer: c.VkBuffer,
index_buffer_memory: c.VkDeviceMemory,
uniform_buffers: []c.VkBuffer,
uniform_buffers_memory: []c.VkDeviceMemory,
uniform_buffers_mapped: []?*anyopaque,
descriptor_pool: c.VkDescriptorPool,
descriptor_sets: []c.VkDescriptorSet,
command_buffers: []c.VkCommandBuffer,
image_available_semaphores: []c.VkSemaphore,
render_finished_semaphores: []c.VkSemaphore,
in_flight_fences: []c.VkFence,

pub fn init(
    allocator: std.mem.Allocator,
    hinstance: win.HINSTANCE,
    window_hwnd: win.HWND,
) !@This() {
    start_time = std.time.microTimestamp();

    const vk_instance = try createInstance();
    const surface = try createSurface(vk_instance, hinstance, window_hwnd);

    // TODO let user specify which device to use (user_set_device param)

    const physical_devices: []c.VkPhysicalDevice = try getPhysicalDevices(allocator, vk_instance);
    defer allocator.free(physical_devices);

    var physical_device: c.VkPhysicalDevice = undefined;
    var swapchain_support: SwapChainSupportDetails = undefined;

    physical_device = for (physical_devices) |device| {
        if (try isDeviceSuitable(allocator, device, surface, &swapchain_support))
            break device;
    } else return error.FailedToFindSuitablePhysicalDevice;

    defer allocator.free(swapchain_support.formats);
    defer allocator.free(swapchain_support.present_modes);

    var device_properties: c.VkPhysicalDeviceProperties = std.mem.zeroes(c.VkPhysicalDeviceProperties);
    c.vkGetPhysicalDeviceProperties(physical_device, &device_properties);
    std.debug.print("physical device {}: {s}, type {}\n", .{
        device_properties.deviceID,
        device_properties.deviceName,
        device_properties.deviceType,
    });

    const queue_family_indices: QueueFamilyIndices = try findQueueFamilies(
        allocator,
        physical_device,
        surface,
    );
    std.debug.assert(queue_family_indices.graphics_family != null and
        queue_family_indices.present_family != null);
    std.debug.print("graphics queue idx: {}, present queue idx: {}\n", .{
        queue_family_indices.graphics_family.?,
        queue_family_indices.present_family.?,
    });

    const enabled_features: c.VkPhysicalDeviceFeatures = .{};
    const device: c.VkDevice = try createLogicalDevice(
        allocator,
        physical_device,
        queue_family_indices,
        enabled_features,
    );

    var graphics_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(
        device,
        queue_family_indices.graphics_family.?,
        0,
        &graphics_queue,
    );

    var present_queue: c.VkQueue = undefined;
    c.vkGetDeviceQueue(
        device,
        queue_family_indices.present_family.?,
        0,
        &present_queue,
    );

    const surface_format: c.VkSurfaceFormatKHR = try chooseSwapSurfaceFormat(swapchain_support.formats);
    const extent: c.VkExtent2D = try chooseSwapExtent(swapchain_support.capabilities);
    const swapchain = try createSwapChain(
        swapchain_support,
        surface,
        surface_format,
        extent,
        device,
        queue_family_indices,
    );

    var image_count: u32 = undefined;
    _ = c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, null);
    const swapchain_images = try allocator.alloc(c.VkImage, image_count);
    _ = c.vkGetSwapchainImagesKHR(device, swapchain, &image_count, swapchain_images.ptr);

    const swapchain_image_views = try createImageViews(
        allocator,
        device,
        swapchain_images,
        surface_format.format,
    );

    const render_pass = try createRenderPass(device, surface_format.format);

    const descriptor_set_layout = try createDescriptorSetLayout(device);

    var pipeline_layout: c.VkPipelineLayout = undefined;
    const pipeline = try createGraphicsPipeline(device, extent, render_pass, &pipeline_layout, descriptor_set_layout);

    const swapchain_framebuffers = try createFramebuffers(
        allocator,
        device,
        swapchain_image_views,
        render_pass,
        extent,
    );

    const command_pool = try createCommandPool(device, queue_family_indices);

    var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
    c.vkGetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);
    var vertex_buffer: c.VkBuffer = undefined;
    var vertex_buffer_memory: c.VkDeviceMemory = undefined;
    try createVertexBuffer(
        device,
        mem_properties,
        &vertex_buffer,
        &vertex_buffer_memory,
        command_pool,
        graphics_queue,
    );

    var index_buffer: c.VkBuffer = undefined;
    var index_buffer_memory: c.VkDeviceMemory = undefined;
    try createIndexBuffer(
        device,
        mem_properties,
        &index_buffer,
        &index_buffer_memory,
        command_pool,
        graphics_queue,
    );

    const uniform_buffers = try allocator.alloc(c.VkBuffer, max_frames_in_flight);
    const uniform_buffers_memory = try allocator.alloc(c.VkDeviceMemory, max_frames_in_flight);
    const uniform_buffers_mapped = try allocator.alloc(?*anyopaque, max_frames_in_flight);
    try createUniformBuffers(device, mem_properties, uniform_buffers, uniform_buffers_memory, uniform_buffers_mapped);

    const descriptor_pool = try createDescriptorPool(device);
    const descriptor_sets = try createDescriptorSets(
        allocator,
        device,
        descriptor_set_layout,
        descriptor_pool,
        uniform_buffers,
    );

    const command_buffers = try createCommandBuffers(allocator, device, command_pool);

    const sync_objects = try createSyncObjects(allocator, device);

    return .{
        .instance = vk_instance,
        .surface = surface,
        .physical_device = physical_device,
        .device = device,
        .graphics_queue = graphics_queue,
        .present_queue = present_queue,
        .swapchain = swapchain,
        .swapchain_image_format = surface_format.format,
        .swapchain_extent = extent,
        .swapchain_images = swapchain_images,
        .swapchain_image_views = swapchain_image_views,
        .swapchain_framebuffers = swapchain_framebuffers,
        .render_pass = render_pass,
        .descriptor_set_layout = descriptor_set_layout,
        .pipeline_layout = pipeline_layout,
        .pipeline = pipeline,
        .command_pool = command_pool,
        .vertex_buffer = vertex_buffer,
        .vertex_buffer_memory = vertex_buffer_memory,
        .index_buffer = index_buffer,
        .index_buffer_memory = index_buffer_memory,
        .uniform_buffers = uniform_buffers,
        .uniform_buffers_memory = uniform_buffers_memory,
        .uniform_buffers_mapped = uniform_buffers_mapped,
        .descriptor_pool = descriptor_pool,
        .descriptor_sets = descriptor_sets,
        .command_buffers = command_buffers,
        .image_available_semaphores = sync_objects.image_available_semaphores,
        .render_finished_semaphores = sync_objects.render_finished_semaphores,
        .in_flight_fences = sync_objects.in_flight_fences,
    };
}

pub fn destroy(self: @This()) void {
    _ = c.vkDeviceWaitIdle(self.device);

    for (0..max_frames_in_flight) |i| {
        c.vkDestroySemaphore(self.device, self.image_available_semaphores[i], null);
        c.vkDestroySemaphore(self.device, self.render_finished_semaphores[i], null);
        c.vkDestroyFence(self.device, self.in_flight_fences[i], null);
    }
    c.vkDestroyBuffer(self.device, self.index_buffer, null);
    c.vkFreeMemory(self.device, self.index_buffer_memory, null);
    c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
    c.vkFreeMemory(self.device, self.vertex_buffer_memory, null);
    c.vkDestroyCommandPool(self.device, self.command_pool, null);
    for (self.swapchain_framebuffers) |framebuffer| {
        c.vkDestroyFramebuffer(self.device, framebuffer, null);
    }
    c.vkDestroyPipeline(self.device, self.pipeline, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    for (0..max_frames_in_flight) |i| {
        c.vkDestroyBuffer(self.device, self.uniform_buffers[i], null);
        c.vkFreeMemory(self.device, self.uniform_buffers_memory[i], null);
    }
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
    c.vkDestroyRenderPass(self.device, self.render_pass, null);
    c.vkDestroyDescriptorPool(self.device, self.descriptor_pool, null);
    c.vkDestroyDescriptorSetLayout(self.device, self.descriptor_set_layout, null);
    for (self.swapchain_image_views) |image_view| {
        c.vkDestroyImageView(self.device, image_view, null);
    }
    c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
    c.vkDestroyDevice(self.device, null);
    c.vkDestroySurfaceKHR(self.instance, self.surface, null);
    c.vkDestroyInstance(self.instance, null);
}

fn createInstance() !c.VkInstance {
    var app_info = c.VkApplicationInfo{
        .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = null,
        .pApplicationName = "pity",
        .applicationVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .pEngineName = "none",
        .engineVersion = c.VK_MAKE_VERSION(1, 0, 0),
        .apiVersion = c.VK_API_VERSION_1_0,
    };

    const extensions = [_][*c]const u8{
        c.VK_KHR_SURFACE_EXTENSION_NAME,
        c.VK_KHR_WIN32_SURFACE_EXTENSION_NAME,
    };

    var create_info = c.VkInstanceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .pApplicationInfo = &app_info,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = null,
        .enabledExtensionCount = extensions.len,
        .ppEnabledExtensionNames = @ptrCast(&extensions),
    };

    var instance: c.VkInstance = undefined;
    std.debug.assert(c.vkCreateInstance(&create_info, null, &instance) == c.VK_SUCCESS);

    return instance;
}

fn createSurface(vk_instance: c.VkInstance, hinstance: win.HINSTANCE, window_hwnd: win.HWND) !c.VkSurfaceKHR {
    var surface: c.VkSurfaceKHR = undefined;

    const create_info = c.VkWin32SurfaceCreateInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
        .pNext = null,
        .flags = 0,
        .hinstance = @ptrCast(@alignCast(@constCast(hinstance))),
        .hwnd = @ptrCast(@alignCast(@constCast(window_hwnd))),
    };

    std.debug.assert(c.vkCreateWin32SurfaceKHR(vk_instance, &create_info, null, &surface) == c.VK_SUCCESS);

    return surface;
}

fn findQueueFamilies(
    allocator: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !QueueFamilyIndices {
    var queue_family_indices: QueueFamilyIndices = undefined;

    var queue_family_count: u32 = 0;
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

    const queue_families = try allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
    c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

    var present_support: c.VkBool32 = c.VK_FALSE;
    for (queue_families, 0..) |queue_family, i| {
        if (queue_family.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
            queue_family_indices.graphics_family = @intCast(i);
        }

        _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), surface, &present_support);
        if (present_support == c.VK_TRUE) queue_family_indices.present_family = @intCast(i);

        if (queue_family_indices.graphics_family != null and queue_family_indices.present_family != null) break;
    }

    return queue_family_indices;
}

fn isDeviceSuitable(
    allocator: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
    swapchain_support_ptr: *SwapChainSupportDetails,
) !bool {
    //var device_features: c.VkPhysicalDeviceFeatures = undefined;
    //c.vkGetPhysicalDeviceFeatures(device, &device_features);

    var required_extensions: std.BufSet = .init(allocator);

    for (required_device_extensions) |extension| try required_extensions.insert(extension);

    var property_count: u32 = 0;
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &property_count, null);

    const properties = try allocator.alloc(c.VkExtensionProperties, property_count);
    _ = c.vkEnumerateDeviceExtensionProperties(device, null, &property_count, properties.ptr);

    for (properties) |property| {
        const cstr_ptr: [*:0]const u8 = @ptrCast(&property.extensionName);
        const name_slice = std.mem.span(cstr_ptr);
        required_extensions.remove(name_slice);
    }

    if (required_extensions.count() == 0) {
        const swapchain_support: SwapChainSupportDetails = try querySwapChainSupport(
            allocator,
            device,
            surface,
        );
        if (swapchain_support.formats.len != 0 and
            swapchain_support.present_modes.len != 0)
        {
            swapchain_support_ptr.* = swapchain_support;
            return true;
        }
    }

    return false;
}

fn getPhysicalDevices(allocator: std.mem.Allocator, vk_instance: c.VkInstance) ![]c.VkPhysicalDevice {
    var device_count: u32 = 0;
    _ = c.vkEnumeratePhysicalDevices(vk_instance, &device_count, null);

    std.debug.assert(device_count > 0);

    const devices = try allocator.alloc(c.VkPhysicalDevice, device_count);
    _ = c.vkEnumeratePhysicalDevices(vk_instance, &device_count, devices.ptr);

    return devices;
}

fn createLogicalDevice(
    allocator: std.mem.Allocator,
    physical_device: c.VkPhysicalDevice,
    queue_family_indices: QueueFamilyIndices,
    enabled_features: c.VkPhysicalDeviceFeatures,
) !c.VkDevice {
    var queue_create_infos: std.ArrayList(c.VkDeviceQueueCreateInfo) = try .initCapacity(allocator, 2);
    defer queue_create_infos.deinit(allocator);

    const g_queue_create_info: c.VkDeviceQueueCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = queue_family_indices.graphics_family.?,
        .queueCount = 1,
        .pQueuePriorities = &@as(f32, 1.0),
    };
    try queue_create_infos.append(allocator, g_queue_create_info);

    if (queue_family_indices.graphics_family.? != queue_family_indices.present_family.?) {
        const p_queue_create_info: c.VkDeviceQueueCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .queueFamilyIndex = queue_family_indices.present_family.?,
            .queueCount = 1,
            .pQueuePriorities = &@as(f32, 1.0),
        };
        try queue_create_infos.append(allocator, p_queue_create_info);
    }

    const create_info: c.VkDeviceCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pQueueCreateInfos = queue_create_infos.items.ptr,
        .queueCreateInfoCount = @intCast(queue_create_infos.items.len),
        .enabledExtensionCount = required_device_extensions.len,
        .ppEnabledExtensionNames = @ptrCast(@constCast(&required_device_extensions)),
        .pEnabledFeatures = &enabled_features,
    };

    var device: c.VkDevice = undefined;
    std.debug.assert(c.vkCreateDevice(physical_device, &create_info, null, &device) == c.VK_SUCCESS);

    return device;
}

fn querySwapChainSupport(
    allocator: std.mem.Allocator,
    device: c.VkPhysicalDevice,
    surface: c.VkSurfaceKHR,
) !SwapChainSupportDetails {
    var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
    _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities);

    var format_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null);

    const formats = try allocator.alloc(c.VkSurfaceFormatKHR, format_count);
    if (format_count != 0)
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr);

    var present_mode_count: u32 = 0;
    _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null);

    const present_modes = try allocator.alloc(c.VkPresentModeKHR, present_mode_count);
    if (present_mode_count != 0)
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(
            device,
            surface,
            &present_mode_count,
            present_modes.ptr,
        );

    return .{
        .capabilities = capabilities,
        .formats = formats,
        .present_modes = present_modes,
    };
}

fn chooseSwapSurfaceFormat(available_formats: []c.VkSurfaceFormatKHR) !c.VkSurfaceFormatKHR {
    for (available_formats) |available_format| {
        if (available_format.format == c.VK_FORMAT_B8G8R8A8_SRGB and
            available_format.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
        {
            return available_format;
        }
    }

    return available_formats[0];
}

fn chooseSwapPresentMode(available_present_modes: []c.VkPresentModeKHR) !c.VkPresentModeKHR {
    for (available_present_modes) |available_present_mode| {
        if (available_present_mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
            return available_present_mode;
        }
    }

    return c.VK_PRESENT_MODE_FIFO_KHR;
}

fn chooseSwapExtent(capabilities: c.VkSurfaceCapabilitiesKHR) !c.VkExtent2D {
    if (capabilities.currentExtent.width != std.math.maxInt(u32)) {
        return capabilities.currentExtent;
    } else {
        var actual_extent: c.VkExtent2D = .{
            .width = width,
            .height = height,
        };

        actual_extent.width = @max(
            capabilities.minImageExtent.width,
            @min(capabilities.maxImageExtent.width, actual_extent.width),
        );
        actual_extent.height = @max(
            capabilities.minImageExtent.height,
            @min(capabilities.maxImageExtent.height, actual_extent.height),
        );

        return actual_extent;
    }
}

fn createSwapChain(
    swapchain_support: SwapChainSupportDetails,
    surface: c.VkSurfaceKHR,
    surface_format: c.VkSurfaceFormatKHR,
    extent: c.VkExtent2D,
    device: c.VkDevice,
    queue_family_indices: QueueFamilyIndices,
) !c.VkSwapchainKHR {
    const present_mode: c.VkPresentModeKHR = try chooseSwapPresentMode(swapchain_support.present_modes);

    var image_count: u32 = swapchain_support.capabilities.minImageCount + 1;
    if (swapchain_support.capabilities.maxImageCount > 0 and
        image_count > swapchain_support.capabilities.maxImageCount)
    {
        image_count = swapchain_support.capabilities.maxImageCount;
    }

    var create_info: c.VkSwapchainCreateInfoKHR = .{
        .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = image_count,
        .imageFormat = surface_format.format,
        .imageColorSpace = surface_format.colorSpace,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = swapchain_support.capabilities.currentTransform,
        .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = c.VK_TRUE,
        .oldSwapchain = null,
    };

    if (!queue_family_indices.same()) {
        create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
        create_info.queueFamilyIndexCount = 2;
        create_info.pQueueFamilyIndices = @ptrCast(@constCast(&queue_family_indices.to_array()));
    } else {
        create_info.imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE;
        create_info.queueFamilyIndexCount = 0; // optional
        create_info.pQueueFamilyIndices = null; // optional
    }

    var swapchain: c.VkSwapchainKHR = undefined;
    std.debug.assert(c.vkCreateSwapchainKHR(device, &create_info, null, &swapchain) == c.VK_SUCCESS);

    return swapchain;
}

fn createImageViews(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    swapchain_images: []c.VkImage,
    format: c.VkFormat,
) ![]c.VkImageView {
    var swapchain_image_views = try allocator.alloc(c.VkImageView, swapchain_images.len);
    errdefer allocator.free(swapchain_image_views);

    for (swapchain_images, 0..) |image, i| {
        var create_info: c.VkImageViewCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image,
            .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = .{
                .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };
        std.debug.assert(c.vkCreateImageView(device, &create_info, null, &swapchain_image_views[i]) == c.VK_SUCCESS);
    }

    return swapchain_image_views;
}

fn createShaderModule(code: []align(@alignOf(u32)) const u8, device: c.VkDevice) !c.VkShaderModule {
    const create_info: c.VkShaderModuleCreateInfo = .{
        .sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = std.mem.bytesAsSlice(u32, code).ptr,
    };

    var shader_module: c.VkShaderModule = undefined;
    std.debug.assert(c.vkCreateShaderModule(device, &create_info, null, &shader_module) == c.VK_SUCCESS);

    return shader_module;
}

fn createRenderPass(device: c.VkDevice, swapchain_image_format: c.VkFormat) !c.VkRenderPass {
    const color_attachment = c.VkAttachmentDescription{
        .format = swapchain_image_format,
        .samples = c.VK_SAMPLE_COUNT_1_BIT,
        .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    const subpass = c.VkSubpassDescription{
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
    };

    const dependency = c.VkSubpassDependency{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .srcAccessMask = 0,
        .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    };

    const render_pass_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = 1,
        .pAttachments = &color_attachment,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    var render_pass: c.VkRenderPass = undefined;
    std.debug.assert(c.vkCreateRenderPass(device, &render_pass_info, null, &render_pass) == c.VK_SUCCESS);

    return render_pass;
}

fn createDescriptorSetLayout(device: c.VkDevice) !c.VkDescriptorSetLayout {
    const ubo_layout_binding = c.VkDescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .stageFlags = c.VK_SHADER_STAGE_VERTEX_BIT,
        .pImmutableSamplers = null, // Optional
    };

    const layout_info = c.VkDescriptorSetLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = 1,
        .pBindings = &ubo_layout_binding,
    };

    var descriptor_set_layout: c.VkDescriptorSetLayout = undefined;
    std.debug.assert(c.vkCreateDescriptorSetLayout(device, &layout_info, null, &descriptor_set_layout) == c.VK_SUCCESS);

    return descriptor_set_layout;
}

fn createGraphicsPipeline(
    device: c.VkDevice,
    swapchain_extent: c.VkExtent2D,
    render_pass: c.VkRenderPass,
    pipeline_layout: *c.VkPipelineLayout,
    descriptor_set_layout: c.VkDescriptorSetLayout,
) !c.VkPipeline {
    const vert_shader align(4) = @embedFile("shaders/vert.spv").*;
    const vert_shader_module: c.VkShaderModule = try createShaderModule(&vert_shader, device);
    defer c.vkDestroyShaderModule(device, vert_shader_module, null);

    const frag_shader align(4) = @embedFile("shaders/frag.spv").*;
    const frag_shader_module: c.VkShaderModule = try createShaderModule(&frag_shader, device);
    defer c.vkDestroyShaderModule(device, frag_shader_module, null);

    const vert_shader_stage = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_VERTEX_BIT,
        .module = vert_shader_module,
        .pName = "main",
    };

    const frag_shader_stage = c.VkPipelineShaderStageCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .stage = c.VK_SHADER_STAGE_FRAGMENT_BIT,
        .module = frag_shader_module,
        .pName = "main",
    };

    const stages = [_]c.VkPipelineShaderStageCreateInfo{
        vert_shader_stage,
        frag_shader_stage,
    };

    const binding_description = Vertex.getBindingDescription();
    const attribute_descriptions = Vertex.getAttributeDescriptions();

    const vertex_input_state = c.VkPipelineVertexInputStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
        .vertexBindingDescriptionCount = 1,
        .pVertexBindingDescriptions = &binding_description,
        .vertexAttributeDescriptionCount = attribute_descriptions.len,
        .pVertexAttributeDescriptions = &attribute_descriptions,
    };

    const input_assembly_state = c.VkPipelineInputAssemblyStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        .topology = c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST, // TODO use VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        .primitiveRestartEnable = c.VK_FALSE, // TODO use VK_TRUE
    };

    const viewport = c.VkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(swapchain_extent.width),
        .height = @floatFromInt(swapchain_extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = swapchain_extent,
    };

    //const dynamic_states = c.VkDynamicState{ c.VK_DYNAMIC_STATE_VIEWPORT, c.VK_DYNAMIC_STATE_SCISSOR };
    //
    //const dynamic_state = c.VkPipelineDynamicStateCreateInfo{
    //    .sType = c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
    //    .dynamicStateCount = dynamic_states.len,
    //    .pDynamicStates = dynamic_states,
    //};
    //
    //const viewport_state = c.VkPipelineViewportStateCreateInfo{
    //    .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
    //    .viewportCount = 1,
    //    .scissorCount = 1,
    //};
    const viewport_state = c.VkPipelineViewportStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        .viewportCount = 1,
        .pViewports = &viewport,
        .scissorCount = 1,
        .pScissors = &scissor,
    };

    const rasterization_state = c.VkPipelineRasterizationStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        .depthClampEnable = c.VK_FALSE,
        .rasterizerDiscardEnable = c.VK_FALSE,
        .polygonMode = c.VK_POLYGON_MODE_FILL,
        .lineWidth = 1.0,
        .cullMode = c.VK_CULL_MODE_BACK_BIT,
        .frontFace = c.VK_FRONT_FACE_COUNTER_CLOCKWISE,
        .depthBiasEnable = c.VK_FALSE,
        .depthBiasConstantFactor = 0.0,
        .depthBiasClamp = 0.0,
        .depthBiasSlopeFactor = 0.0,
    };

    const multisample_state = c.VkPipelineMultisampleStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        .sampleShadingEnable = c.VK_FALSE,
        .rasterizationSamples = c.VK_SAMPLE_COUNT_1_BIT,
        .minSampleShading = 1.0,
        .pSampleMask = null,
        .alphaToCoverageEnable = c.VK_FALSE,
        .alphaToOneEnable = c.VK_FALSE,
    };

    const color_blend_attachment = c.VkPipelineColorBlendAttachmentState{
        .colorWriteMask = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT,
        .blendEnable = c.VK_FALSE,
        .srcColorBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstColorBlendFactor = c.VK_BLEND_FACTOR_ZERO,
        .colorBlendOp = c.VK_BLEND_OP_ADD,
        .srcAlphaBlendFactor = c.VK_BLEND_FACTOR_ONE,
        .dstAlphaBlendFactor = c.VK_BLEND_FACTOR_ZERO,
        .alphaBlendOp = c.VK_BLEND_OP_ADD,
    };

    const color_blend_state = c.VkPipelineColorBlendStateCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        .logicOpEnable = c.VK_FALSE,
        .logicOp = c.VK_LOGIC_OP_COPY,
        .attachmentCount = 1,
        .pAttachments = &color_blend_attachment,
        .blendConstants = .{ 0.0, 0.0, 0.0, 0.0 },
    };

    const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptor_set_layout,
    };

    std.debug.assert(
        c.vkCreatePipelineLayout(
            device,
            &pipeline_layout_info,
            null,
            pipeline_layout,
        ) == c.VK_SUCCESS,
    );

    const pipeline_info = c.VkGraphicsPipelineCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        .stageCount = 2,
        .pStages = &stages,
        .pVertexInputState = &vertex_input_state,
        .pInputAssemblyState = &input_assembly_state,
        .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization_state,
        .pMultisampleState = &multisample_state,
        .pDepthStencilState = null,
        .pColorBlendState = &color_blend_state,
        .pDynamicState = null,
        .layout = pipeline_layout.*,
        .renderPass = render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
        .basePipelineIndex = -1,
    };

    var graphics_pipeline: c.VkPipeline = undefined;
    std.debug.assert(
        c.vkCreateGraphicsPipelines(
            device,
            null,
            1,
            &pipeline_info,
            null,
            &graphics_pipeline,
        ) == c.VK_SUCCESS,
    );

    return graphics_pipeline;
}

fn createFramebuffers(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    image_views: []c.VkImageView,
    render_pass: c.VkRenderPass,
    extent: c.VkExtent2D,
) ![]c.VkFramebuffer {
    var framebuffers = try allocator.alloc(c.VkFramebuffer, image_views.len);

    for (image_views, 0..) |image_view, i| {
        const attachments = [_]c.VkImageView{image_view};

        const framebuffer_info = c.VkFramebufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass,
            .attachmentCount = 1,
            .pAttachments = &attachments,
            .width = extent.width,
            .height = extent.height,
            .layers = 1,
        };

        std.debug.assert(
            c.vkCreateFramebuffer(
                device,
                &framebuffer_info,
                null,
                &framebuffers[i],
            ) == c.VK_SUCCESS,
        );
    }

    return framebuffers;
}

fn createCommandPool(device: c.VkDevice, queue_family_indices: QueueFamilyIndices) !c.VkCommandPool {
    const pool_info = c.VkCommandPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = queue_family_indices.graphics_family.?,
    };

    var command_pool: c.VkCommandPool = undefined;
    std.debug.assert(c.vkCreateCommandPool(device, &pool_info, null, &command_pool) == c.VK_SUCCESS);

    return command_pool;
}

fn findMemoryType(
    mem_properties: c.VkPhysicalDeviceMemoryProperties,
    type_filter: u32,
    properties: c.VkMemoryPropertyFlags,
) !u32 {
    for (0..mem_properties.memoryTypeCount) |i| {
        if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
            (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
        {
            return @intCast(i);
        }
    }
    return error.FailedToFindSuitableMemoryType;
}

fn createBuffer(
    device: c.VkDevice,
    size: c.VkDeviceSize,
    usage: c.VkBufferUsageFlags,
    mem_properties: c.VkPhysicalDeviceMemoryProperties,
    properties: c.VkMemoryPropertyFlags,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkDeviceMemory,
) !void {
    var buffer_info = c.VkBufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
        .size = size,
        .usage = usage,
        .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
    };
    std.debug.assert(c.vkCreateBuffer(device, &buffer_info, null, buffer) == c.VK_SUCCESS);

    var mem_requirements: c.VkMemoryRequirements = undefined;
    c.vkGetBufferMemoryRequirements(device, buffer.*, &mem_requirements);

    const alloc_info = c.VkMemoryAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
        .allocationSize = mem_requirements.size,
        .memoryTypeIndex = try findMemoryType(
            mem_properties,
            mem_requirements.memoryTypeBits,
            properties,
        ),
    };
    std.debug.assert(c.vkAllocateMemory(device, &alloc_info, null, buffer_memory) == c.VK_SUCCESS);

    _ = c.vkBindBufferMemory(device, buffer.*, buffer_memory.*, 0);
}

fn copyBuffer(
    device: c.VkDevice,
    src_buffer: c.VkBuffer,
    dst_buffer: c.VkBuffer,
    size: c.VkDeviceSize,
    command_pool: c.VkCommandPool,
    graphics_queue: c.VkQueue,
) !void {
    const alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandPool = command_pool,
        .commandBufferCount = 1,
    };

    var command_buffer: c.VkCommandBuffer = undefined;
    _ = c.vkAllocateCommandBuffers(device, &alloc_info, &command_buffer);

    const begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
    };

    _ = c.vkBeginCommandBuffer(command_buffer, &begin_info);

    const copy_region = c.VkBufferCopy{
        .srcOffset = 0, // Optional
        .dstOffset = 0, // Optional
        .size = size,
    };
    c.vkCmdCopyBuffer(command_buffer, src_buffer, dst_buffer, 1, &copy_region);

    _ = c.vkEndCommandBuffer(command_buffer);

    const submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .commandBufferCount = 1,
        .pCommandBuffers = &command_buffer,
    };

    _ = c.vkQueueSubmit(graphics_queue, 1, &submit_info, null);
    _ = c.vkQueueWaitIdle(graphics_queue);

    c.vkFreeCommandBuffers(device, command_pool, 1, &command_buffer);
}

fn createVertexBuffer(
    device: c.VkDevice,
    mem_properties: c.VkPhysicalDeviceMemoryProperties,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkDeviceMemory,
    command_pool: c.VkCommandPool,
    graphics_queue: c.VkQueue,
) !void {
    const size = @sizeOf(Vertex) * vertices.len;

    var staging_buffer: c.VkBuffer = undefined;
    var staging_buffer_memory: c.VkDeviceMemory = undefined;
    try createBuffer(
        device,
        size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        mem_properties,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &staging_buffer,
        &staging_buffer_memory,
    );

    var data: ?*anyopaque = null;
    _ = c.vkMapMemory(device, staging_buffer_memory, 0, size, 0, &data);
    if (data) |ptr| {
        const dest = @as([*]u8, @ptrCast(ptr))[0..size];
        const source: [*]u8 = @ptrCast(@constCast(&vertices));
        @memcpy(dest, source);
    }
    _ = c.vkUnmapMemory(device, staging_buffer_memory);

    try createBuffer(
        device,
        size,
        c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
        mem_properties,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        buffer,
        buffer_memory,
    );

    try copyBuffer(
        device,
        staging_buffer,
        buffer.*,
        size,
        command_pool,
        graphics_queue,
    );

    c.vkDestroyBuffer(device, staging_buffer, null);
    c.vkFreeMemory(device, staging_buffer_memory, null);
}

fn createIndexBuffer(
    device: c.VkDevice,
    mem_properties: c.VkPhysicalDeviceMemoryProperties,
    buffer: *c.VkBuffer,
    buffer_memory: *c.VkBuffer,
    command_pool: c.VkCommandPool,
    graphics_queue: c.VkQueue,
) !void {
    const size: c.VkDeviceSize = @sizeOf(u16) * indices.len;

    var staging_buffer: c.VkBuffer = undefined;
    var staging_buffer_memory: c.VkDeviceMemory = undefined;
    try createBuffer(
        device,
        size,
        c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
        mem_properties,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        &staging_buffer,
        &staging_buffer_memory,
    );

    var data: ?*anyopaque = null;
    _ = c.vkMapMemory(device, staging_buffer_memory, 0, size, 0, &data);
    if (data) |ptr| {
        const dest = @as([*]u8, @ptrCast(ptr))[0..size];
        const source: [*]u8 = @ptrCast(@constCast(&indices));
        @memcpy(dest, source);
    }
    _ = c.vkUnmapMemory(device, staging_buffer_memory);

    try createBuffer(
        device,
        size,
        c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_INDEX_BUFFER_BIT,
        mem_properties,
        c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        buffer,
        buffer_memory,
    );

    try copyBuffer(
        device,
        staging_buffer,
        buffer.*,
        size,
        command_pool,
        graphics_queue,
    );

    c.vkDestroyBuffer(device, staging_buffer, null);
    c.vkFreeMemory(device, staging_buffer_memory, null);
}

fn createUniformBuffers(
    device: c.VkDevice,
    mem_properties: c.VkPhysicalDeviceMemoryProperties,
    uniform_buffers: []c.VkBuffer,
    uniform_buffers_memory: []c.VkDeviceMemory,
    uniform_buffers_mapped: []?*anyopaque,
) !void {
    const buffer_size: c.VkDeviceSize = @sizeOf(UniformBufferObject);

    for (0..max_frames_in_flight) |i| {
        try createBuffer(
            device,
            buffer_size,
            c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            mem_properties,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            &uniform_buffers[i],
            &uniform_buffers_memory[i],
        );

        _ = c.vkMapMemory(device, uniform_buffers_memory[i], 0, buffer_size, 0, &uniform_buffers_mapped[i]);
    }
}

fn createDescriptorPool(device: c.VkDevice) !c.VkDescriptorPool {
    const pool_size = c.VkDescriptorPoolSize{
        .type = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = @intCast(max_frames_in_flight),
    };

    const pool_info = c.VkDescriptorPoolCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = 1,
        .pPoolSizes = &pool_size,
        .maxSets = @intCast(max_frames_in_flight),
    };

    var descriptor_pool: c.VkDescriptorPool = undefined;
    std.debug.assert(c.vkCreateDescriptorPool(device, &pool_info, null, &descriptor_pool) == c.VK_SUCCESS);

    return descriptor_pool;
}

fn createDescriptorSets(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    descriptor_set_layout: c.VkDescriptorSetLayout,
    descriptor_pool: c.VkDescriptorPool,
    uniform_buffers: []c.VkBuffer,
) ![]c.VkDescriptorSet {
    const layouts = [_]c.VkDescriptorSetLayout{descriptor_set_layout} ** max_frames_in_flight;
    const alloc_info = c.VkDescriptorSetAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = descriptor_pool,
        .descriptorSetCount = @intCast(max_frames_in_flight),
        .pSetLayouts = &layouts,
    };

    const descriptor_sets = try allocator.alloc(c.VkDescriptorSet, max_frames_in_flight);
    std.debug.assert(c.vkAllocateDescriptorSets(device, &alloc_info, descriptor_sets.ptr) == c.VK_SUCCESS);

    for (0..max_frames_in_flight) |i| {
        const buffer_info = c.VkDescriptorBufferInfo{
            .buffer = uniform_buffers[i],
            .offset = 0,
            .range = @sizeOf(UniformBufferObject),
        };

        const descriptor_write = c.VkWriteDescriptorSet{
            .sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = descriptor_sets[i],
            .dstBinding = 0,
            .dstArrayElement = 0,
            .descriptorType = c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &buffer_info,
            .pImageInfo = null, // Optional
            .pTexelBufferView = null, // Optional
        };

        c.vkUpdateDescriptorSets(device, 1, &descriptor_write, 0, null);
    }

    return descriptor_sets;
}

fn createCommandBuffers(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
    command_pool: c.VkCommandPool,
) ![]c.VkCommandBuffer {
    const alloc_info = c.VkCommandBufferAllocateInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = command_pool,
        .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = max_frames_in_flight,
    };

    const command_buffers = try allocator.alloc(c.VkCommandBuffer, max_frames_in_flight);
    std.debug.assert(c.vkAllocateCommandBuffers(device, &alloc_info, command_buffers.ptr) == c.VK_SUCCESS);

    return command_buffers;
}

fn recordCommandBuffer(
    self: @This(),
    command_buffer: c.VkCommandBuffer,
    image_index: u32,
) !void {
    var begin_info = c.VkCommandBufferBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .flags = 0,
        .pInheritanceInfo = null,
    };

    std.debug.assert(c.vkBeginCommandBuffer(command_buffer, &begin_info) == c.VK_SUCCESS);

    const clear_color = c.VkClearValue{ .color = .{ .float32 = .{ 0.0, 0.0, 0.0, 1.0 } } };
    const render_pass_info = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.swapchain_framebuffers[image_index],
        .renderArea = .{ .offset = c.VkOffset2D{ .x = 0, .y = 0 }, .extent = self.swapchain_extent },
        .clearValueCount = 1,
        .pClearValues = &clear_color,
    };

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

    //VkViewport viewport{};
    //viewport.x = 0.0f;
    //viewport.y = 0.0f;
    //viewport.width = static_cast<float>(swapChainExtent.width);
    //viewport.height = static_cast<float>(swapChainExtent.height);
    //viewport.minDepth = 0.0f;
    //viewport.maxDepth = 1.0f;
    //vkCmdSetViewport(commandBuffer, 0, 1, &viewport);

    //VkRect2D scissor{};
    //scissor.offset = {0, 0};
    //scissor.extent = swapChainExtent;
    //vkCmdSetScissor(commandBuffer, 0, 1, &scissor);

    const vertex_buffers = [_]c.VkBuffer{self.vertex_buffer};
    const offsets = [_]c.VkDeviceSize{0};
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vertex_buffers, &offsets);

    c.vkCmdBindIndexBuffer(command_buffer, self.index_buffer, 0, c.VK_INDEX_TYPE_UINT16);

    c.vkCmdBindDescriptorSets(
        command_buffer,
        c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        self.pipeline_layout,
        0,
        1,
        &self.descriptor_sets[current_frame],
        0,
        null,
    );

    //c.vkCmdDraw(command_buffer, vertices.len, 1, 0, 0);
    c.vkCmdDrawIndexed(command_buffer, indices.len, 1, 0, 0, 0);

    c.vkCmdEndRenderPass(command_buffer);
    std.debug.assert(c.vkEndCommandBuffer(command_buffer) == c.VK_SUCCESS);
}

const SyncObjects = struct {
    image_available_semaphores: []c.VkSemaphore,
    render_finished_semaphores: []c.VkSemaphore,
    in_flight_fences: []c.VkFence,
};

fn createSyncObjects(
    allocator: std.mem.Allocator,
    device: c.VkDevice,
) !SyncObjects {
    const semaphore_info = c.VkSemaphoreCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };
    const fenceInfo = c.VkFenceCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
    };

    const image_available_semaphores = try allocator.alloc(c.VkSemaphore, max_frames_in_flight);
    const render_finished_semaphores = try allocator.alloc(c.VkSemaphore, max_frames_in_flight);
    const in_flight_fences = try allocator.alloc(c.VkFence, max_frames_in_flight);

    for (0..max_frames_in_flight) |i| {
        std.debug.assert(
            c.vkCreateSemaphore(
                device,
                &semaphore_info,
                null,
                &image_available_semaphores[i],
            ) == c.VK_SUCCESS,
        );
        std.debug.assert(
            c.vkCreateSemaphore(
                device,
                &semaphore_info,
                null,
                &render_finished_semaphores[i],
            ) == c.VK_SUCCESS,
        );
        std.debug.assert(
            c.vkCreateFence(
                device,
                &fenceInfo,
                null,
                &in_flight_fences[i],
            ) == c.VK_SUCCESS,
        );
    }

    return .{
        .image_available_semaphores = image_available_semaphores,
        .render_finished_semaphores = render_finished_semaphores,
        .in_flight_fences = in_flight_fences,
    };
}
fn rotate(angle: f32, axis: [3]f32) [4][4]f32 {
    const cos_a = @cos(angle);
    const sin_a = @sin(angle);
    const one_minus_cos = 1.0 - cos_a;
    const x = axis[0];
    const y = axis[1];
    const z = axis[2];

    return [4][4]f32{
        .{ cos_a + x * x * one_minus_cos, x * y * one_minus_cos - z * sin_a, x * z * one_minus_cos + y * sin_a, 0.0 },
        .{ y * x * one_minus_cos + z * sin_a, cos_a + y * y * one_minus_cos, y * z * one_minus_cos - x * sin_a, 0.0 },
        .{ z * x * one_minus_cos - y * sin_a, z * y * one_minus_cos + x * sin_a, cos_a + z * z * one_minus_cos, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    };
}

fn lookAt(eye: [3]f32, center: [3]f32, up: [3]f32) [4][4]f32 {
    const f = normalize(.{ center[0] - eye[0], center[1] - eye[1], center[2] - eye[2] });
    const s = normalize(cross(f, up));
    const u = cross(s, f);

    return [4][4]f32{
        .{ s[0], u[0], -f[0], 0.0 },
        .{ s[1], u[1], -f[1], 0.0 },
        .{ s[2], u[2], -f[2], 0.0 },
        .{ -dot(s, eye), -dot(u, eye), dot(f, eye), 1.0 },
    };
}

fn perspective(fov: f32, aspect: f32, near: f32, far: f32) [4][4]f32 {
    const tan_half_fov = @tan(fov / 2.0);
    const f = 1.0 / tan_half_fov;

    return [4][4]f32{
        .{ f / aspect, 0.0, 0.0, 0.0 },
        .{ 0.0, f, 0.0, 0.0 },
        .{ 0.0, 0.0, far / (near - far), -1.0 },
        .{ 0.0, 0.0, (near * far) / (near - far), 0.0 },
    };
}

// Vector math helpers
fn dot(a: [3]f32, b: [3]f32) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn cross(a: [3]f32, b: [3]f32) [3]f32 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn normalize(v: [3]f32) [3]f32 {
    const len = @sqrt(dot(v, v));
    return .{ v[0] / len, v[1] / len, v[2] / len };
}

fn updateUniformBuffer(current_image: u32, swapchain_extent: c.VkExtent2D, uniform_buffers_mapped: []?*anyopaque) !void {
    const current_time = std.time.microTimestamp();
    const time = @as(f32, @floatFromInt(current_time - start_time)) / 1_000_000.0; // Convert to seconds

    var ubo = UniformBufferObject{
        .model = rotate(time * std.math.degreesToRadians(90.0), .{ 0.0, 0.0, 1.0 }),
        .view = lookAt(.{ 2.0, 2.0, 2.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0 }),
        .proj = perspective(
            std.math.degreesToRadians(45.0),
            @as(f32, @floatFromInt(swapchain_extent.width)) / @as(f32, @floatFromInt(swapchain_extent.height)),
            0.1,
            10.0,
        ),
    };
    ubo.proj[1][1] *= -1;

    const dest = @as([*]u8, @ptrCast(uniform_buffers_mapped[current_image]))[0..@sizeOf(UniformBufferObject)];
    const src = @as([*]const u8, @ptrCast(&ubo));
    @memcpy(dest, src);
}

pub fn drawFrame(self: @This()) !void {
    _ = c.vkWaitForFences(self.device, 1, &self.in_flight_fences[current_frame], c.VK_TRUE, c.UINT64_MAX);

    var image_index: u32 = undefined;
    _ = c.vkAcquireNextImageKHR(
        self.device,
        self.swapchain,
        c.UINT64_MAX,
        self.image_available_semaphores[current_frame],
        null,
        &image_index,
    );

    try updateUniformBuffer(current_frame, self.swapchain_extent, self.uniform_buffers_mapped);

    _ = c.vkResetFences(self.device, 1, &self.in_flight_fences[current_frame]);

    _ = c.vkResetCommandBuffer(self.command_buffers[current_frame], 0);
    try self.recordCommandBuffer(self.command_buffers[current_frame], image_index);

    const wait_semaphores = [_]c.VkSemaphore{self.image_available_semaphores[current_frame]};
    const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
    const signal_semaphores = [_]c.VkSemaphore{self.render_finished_semaphores[current_frame]};
    const submit_info = c.VkSubmitInfo{
        .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &wait_semaphores,
        .pWaitDstStageMask = &wait_stages,
        .commandBufferCount = 1,
        .pCommandBuffers = &self.command_buffers[current_frame],
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &signal_semaphores,
        .pNext = null,
    };
    var submits = [_]c.VkSubmitInfo{submit_info};
    std.debug.assert(
        c.vkQueueSubmit(self.graphics_queue, 1, &submits, self.in_flight_fences[current_frame]) == c.VK_SUCCESS,
    );

    const swapchains = [_]c.VkSwapchainKHR{self.swapchain};
    const present_info = c.VkPresentInfoKHR{
        .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &swapchains,
        .pImageIndices = &image_index,
        .pResults = null,
    };
    _ = c.vkQueuePresentKHR(self.present_queue, &present_info);

    current_frame = (current_frame + 1) % max_frames_in_flight;
}
