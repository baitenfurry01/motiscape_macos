import Foundation

struct OpenSourceCredit: Identifiable {
    let name: String
    let purpose: String
    let projectURL: URL
    let license: String
    let licenseURL: URL
    let group: OpenSourceCreditGroup

    var id: String { name }
}

enum OpenSourceCreditGroup: String, CaseIterable, Identifiable {
    case application
    case rendering
    case foundation
    case renderingDependencies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "应用与服务"
        case .rendering: "图形与媒体"
        case .foundation: "基础组件"
        case .renderingDependencies: "渲染器依赖"
        }
    }

    var symbol: String {
        switch self {
        case .application: "app.connected.to.app.below.fill"
        case .rendering: "photo.on.rectangle.angled"
        case .foundation: "shippingbox.fill"
        case .renderingDependencies: "square.stack.3d.up.fill"
        }
    }
}

enum OpenSourceCredits {
    // This list follows production package references, renderer CMake targets,
    // bundled libraries and MoltenVK's dependency manifest. License links point
    // to upstream texts; the labels do not replace their complete terms.
    static let all: [OpenSourceCredit] = [
        .init(
            name: "ZIPFoundation", purpose: "壁纸资源压缩包的读取与解压",
            projectURL: URL(string: "https://github.com/weichsel/ZIPFoundation")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/weichsel/ZIPFoundation/blob/development/LICENSE")!,
            group: .application
        ),
        .init(
            name: "SteamKit2", purpose: "Steam 连接、内容下载与创意工坊服务",
            projectURL: URL(string: "https://github.com/SteamRE/SteamKit")!,
            license: "LGPL-2.1-only",
            licenseURL: URL(string: "https://github.com/SteamRE/SteamKit/blob/master/LICENSE")!,
            group: .application
        ),
        .init(
            name: ".NET", purpose: "Steam 服务的运行环境",
            projectURL: URL(string: "https://github.com/dotnet/runtime")!,
            license: "MIT; third-party notices",
            licenseURL: URL(string: "https://github.com/dotnet/runtime/blob/main/LICENSE.TXT")!,
            group: .application
        ),
        .init(
            name: "protobuf-net / protobuf-net.Core", purpose: "Steam 协议消息的序列化",
            projectURL: URL(string: "https://github.com/protobuf-net/protobuf-net")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/protobuf-net/protobuf-net/blob/main/Licence.txt")!,
            group: .application
        ),
        .init(
            name: "System.IO.Hashing", purpose: "下载内容的哈希计算与校验",
            projectURL: URL(string: "https://github.com/dotnet/runtime/tree/main/src/libraries/System.IO.Hashing")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/dotnet/runtime/blob/main/LICENSE.TXT")!,
            group: .application
        ),
        .init(
            name: "ZstdSharp.Port", purpose: "Steam 下载数据的 Zstandard 解压",
            projectURL: URL(string: "https://github.com/oleg-st/ZstdSharp")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/oleg-st/ZstdSharp/blob/master/LICENSE")!,
            group: .application
        ),
        .init(
            name: "open-wallpaper-engine", purpose: "网页壁纸渲染器的移植基础",
            projectURL: URL(string: "https://github.com/waywallen/open-wallpaper-engine")!,
            license: "GPL-2.0-only",
            licenseURL: URL(string: "https://github.com/waywallen/open-wallpaper-engine/blob/main/LICENSE")!,
            group: .rendering
        ),
        .init(
            name: "QuickJS-NG", purpose: "场景壁纸的 JavaScript 脚本运行时",
            projectURL: URL(string: "https://github.com/quickjs-ng/quickjs")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/quickjs-ng/quickjs/blob/master/LICENSE")!,
            group: .rendering
        ),
        .init(
            name: "glslang", purpose: "场景着色器的编译与转换",
            projectURL: URL(string: "https://github.com/KhronosGroup/glslang")!,
            license: "BSD-3-Clause / BSD-2-Clause / MIT / Apache-2.0 / GPL-3.0 with Bison exception / NVIDIA license",
            licenseURL: URL(string: "https://github.com/KhronosGroup/glslang/blob/main/LICENSE.txt")!,
            group: .rendering
        ),
        .init(
            name: "SPIRV-Reflect", purpose: "着色器资源绑定与布局分析",
            projectURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Reflect")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Reflect/blob/main/LICENSE")!,
            group: .rendering
        ),
        .init(
            name: "FFmpeg", purpose: "视频与场景壁纸中的音视频解码",
            projectURL: URL(string: "https://github.com/FFmpeg/FFmpeg")!,
            license: "LGPL-2.1-or-later",
            licenseURL: URL(string: "https://github.com/FFmpeg/FFmpeg/blob/master/LICENSE.md")!,
            group: .rendering
        ),
        .init(
            name: "dav1d", purpose: "AV1 视频解码",
            projectURL: URL(string: "https://code.videolan.org/videolan/dav1d")!,
            license: "BSD-2-Clause",
            licenseURL: URL(string: "https://code.videolan.org/videolan/dav1d/-/blob/master/COPYING")!,
            group: .rendering
        ),
        .init(
            name: "MoltenVK", purpose: "通过 Metal 运行 Vulkan 场景渲染",
            projectURL: URL(string: "https://github.com/KhronosGroup/MoltenVK")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/MoltenVK/blob/main/LICENSE")!,
            group: .rendering
        ),
        .init(
            name: "Vulkan Loader", purpose: "Vulkan 图形接口与驱动加载",
            projectURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Loader")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Loader/blob/main/LICENSE.txt")!,
            group: .rendering
        ),
        .init(
            name: "rstd", purpose: "场景引擎的基础类型、JSON 与日志",
            projectURL: URL(string: "https://github.com/hypengw/rstd")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/hypengw/rstd/blob/main/LICENSE")!,
            group: .foundation
        ),
        .init(
            name: "Eigen", purpose: "场景中的向量、矩阵与几何运算",
            projectURL: URL(string: "https://gitlab.com/libeigen/eigen")!,
            license: "MPL-2.0 (core); additional licenses",
            licenseURL: URL(string: "https://gitlab.com/libeigen/eigen/-/blob/3.4.0/COPYING.README")!,
            group: .foundation
        ),
        .init(
            name: "stb_image", purpose: "壁纸纹理与图片解码",
            projectURL: URL(string: "https://github.com/nothings/stb")!,
            license: "MIT OR Unlicense",
            licenseURL: URL(string: "https://github.com/nothings/stb/blob/master/LICENSE")!,
            group: .foundation
        ),
        .init(
            name: "Vulkan Memory Allocator", purpose: "场景渲染的 GPU 内存管理",
            projectURL: URL(string: "https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/blob/master/LICENSE.txt")!,
            group: .foundation
        ),
        .init(
            name: "effolkronium/random", purpose: "场景与粒子效果的随机数工具",
            projectURL: URL(string: "https://github.com/effolkronium/random")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/effolkronium/random/blob/master/include/effolkronium/random.hpp")!,
            group: .foundation
        ),
        .init(
            name: "vog/sha1", purpose: "场景资源的 SHA-1 哈希计算",
            projectURL: URL(string: "https://github.com/vog/sha1")!,
            license: "Public Domain",
            licenseURL: URL(string: "https://github.com/vog/sha1/blob/master/sha1.hpp")!,
            group: .foundation
        ),
        .init(
            name: "FreeType", purpose: "场景文字的字形栅格化",
            projectURL: URL(string: "https://freetype.org")!,
            license: "FTL OR GPL-2.0-or-later",
            licenseURL: URL(string: "https://gitlab.freedesktop.org/freetype/freetype/-/blob/master/docs/LICENSE.TXT")!,
            group: .foundation
        ),
        .init(
            name: "Fontconfig", purpose: "场景文字的字体查找与回退",
            projectURL: URL(string: "https://gitlab.freedesktop.org/fontconfig/fontconfig")!,
            license: "HPND-sell-variant / MIT / MIT-Modern-Variant / Unicode-3.0 / Public Domain",
            licenseURL: URL(string: "https://gitlab.freedesktop.org/fontconfig/fontconfig/-/blob/main/COPYING")!,
            group: .foundation
        ),
        .init(
            name: "LZ4", purpose: "压缩场景纹理的数据解码",
            projectURL: URL(string: "https://github.com/lz4/lz4")!,
            license: "BSD-2-Clause",
            licenseURL: URL(string: "https://github.com/lz4/lz4/blob/dev/lib/LICENSE")!,
            group: .foundation
        ),
        .init(
            name: "libpng", purpose: "字体与图像组件的 PNG 支持",
            projectURL: URL(string: "https://github.com/pnggroup/libpng")!,
            license: "libpng-2.0",
            licenseURL: URL(string: "https://github.com/pnggroup/libpng/blob/libpng16/LICENSE")!,
            group: .foundation
        ),
        .init(
            name: "GNU gettext / libintl", purpose: "字体配置组件的国际化支持",
            projectURL: URL(string: "https://www.gnu.org/software/gettext/")!,
            license: "LGPL-2.1-or-later (libintl)",
            licenseURL: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!,
            group: .foundation
        ),
        .init(
            name: "Vulkan Headers", purpose: "渲染器与 MoltenVK 的 Vulkan 接口定义",
            projectURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Headers")!,
            license: "Apache-2.0 / MIT",
            licenseURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Headers/blob/main/LICENSE.md")!,
            group: .renderingDependencies
        ),
        .init(
            name: "SPIRV-Cross", purpose: "MoltenVK 的着色器交叉编译",
            projectURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Cross")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Cross/blob/main/LICENSE")!,
            group: .renderingDependencies
        ),
        .init(
            name: "SPIRV-Tools", purpose: "MoltenVK 构建中的 SPIR-V 处理工具",
            projectURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Tools")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Tools/blob/main/LICENSE")!,
            group: .renderingDependencies
        ),
        .init(
            name: "SPIRV-Headers", purpose: "着色器工具使用的 SPIR-V 接口定义",
            projectURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Headers")!,
            license: "MIT-Khronos-old / MIT / Public Domain / CC-BY-4.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/SPIRV-Headers/blob/main/LICENSE")!,
            group: .renderingDependencies
        ),
        .init(
            name: "cereal", purpose: "MoltenVK 依赖中的 C++ 序列化支持",
            projectURL: URL(string: "https://github.com/USCiLab/cereal")!,
            license: "BSD-3-Clause",
            licenseURL: URL(string: "https://github.com/USCiLab/cereal/blob/master/LICENSE")!,
            group: .renderingDependencies
        ),
        .init(
            name: "Volk", purpose: "MoltenVK 构建依赖的 Vulkan 函数加载",
            projectURL: URL(string: "https://github.com/zeux/volk")!,
            license: "MIT",
            licenseURL: URL(string: "https://github.com/zeux/volk/blob/master/LICENSE.md")!,
            group: .renderingDependencies
        ),
        .init(
            name: "Vulkan Tools", purpose: "MoltenVK 构建中的 Vulkan 工具支持",
            projectURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Tools")!,
            license: "Apache-2.0",
            licenseURL: URL(string: "https://github.com/KhronosGroup/Vulkan-Tools/blob/main/LICENSE.txt")!,
            group: .renderingDependencies
        ),
    ]
}
