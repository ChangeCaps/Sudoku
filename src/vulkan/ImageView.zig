const std = @import("std");
const vk = @import("vk.zig");

const ImageView = @This();

pub const Descriptor = struct {
    type: vk.ViewType,
    format: vk.ImageFormat,
    aspect: vk.ImageAspects,
    base_mip_level: u32 = 0,
    mip_levels: u32 = 1,
    base_array_layer: u32 = 0,
    array_layers: u32 = 1,
};

vk: vk.api.VkImageView,
device: vk.api.VkDevice,

pub fn init(image: vk.Image, desc: Descriptor) !ImageView {
    return fromVkImage(image.device, image.vk, desc);
}

pub fn fromVkImage(device: vk.api.VkDevice, image: vk.api.VkImage, desc: Descriptor) !ImageView {
    const view_info = vk.api.VkImageViewCreateInfo{
        .sType = vk.api.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .image = image,
        .viewType = @intFromEnum(desc.type),
        .format = @intFromEnum(desc.format),
        .components = vk.api.VkComponentMapping{
            .r = vk.api.VK_COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.api.VK_COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.api.VK_COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.api.VK_COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = vk.api.VkImageSubresourceRange{
            .aspectMask = vk.api.VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = desc.base_mip_level,
            .levelCount = desc.mip_levels,
            .baseArrayLayer = desc.base_array_layer,
            .layerCount = desc.array_layers,
        },
    };

    var view: vk.api.VkImageView = undefined;
    try vk.check(vk.api.vkCreateImageView(device, &view_info, null, &view));

    return .{
        .vk = view,
        .device = device,
    };
}

pub fn deinit(self: ImageView) void {
    vk.api.vkDestroyImageView(self.device, self.vk, null);
}
