export module sr.pkg.scene_obj:sound_object;
import rstd.cppstd;
import wavsen.audio;
import sr.fs;

import sr.json;
export import :field_binding;
import :visibility_binding;
import :scene_document;

export namespace sr

{

namespace wpscene
{

struct SoundObject {
    std::int32_t             id { 0 };
    std::string              playbackmode { "loop" };
    std::array<float, 3>     origin { 0.0f, 0.0f, 0.0f };
    std::array<float, 3>     angles { 0.0f, 0.0f, 0.0f };
    std::array<float, 3>     scale { 1.0f, 1.0f, 1.0f };
    float                    maxtime { 10.0f };
    float                    mintime { 0.0f };
    float                    volume { 1.0f };
    bool                     visible { true };
    std::string              name;
    std::vector<std::string> sound;

    // Common cross-kind metadata.
    bool                      locktransforms { false };
    bool                      muteineditor { false };
    bool                      nointerpolation { false };
    std::uint32_t             parent { 0 };
    std::vector<std::int32_t> dependencies;
    sr::Json                 instance;
    FieldBindings             field_bindings;

    // Sound-kind specifics.
    bool        startsilent { false };    // PKGV0002+
    bool        blockalign { false };     // PKGV0018+
    bool        spatialization { false }; // PKGV0023+
    std::string queuemode;                // PKGV0020+

    VisibleUserBinding visible_user;
    std::string        visible_user_key;
    std::string        volume_user_key;

    bool FromJson(const sr::Json& json, fs::VFS& vfs) {
        return FromJson(json, vfs, kSceneVersionUnknown);
    }

    bool FromJson(const sr::Json& json, fs::VFS&, SceneVersion /*v*/) {
        sr::GetJsonValue(json, "volume", volume);
        if (auto volume_json = json.get("volume");
            volume_json.is_some() && (*volume_json)->is_object()) {
            if (auto user = (*volume_json)->get("user"); user.is_some()) {
                auto string = (*user)->as_str();
                if (string.is_some()) volume_user_key = rstd::cppstd::to_string(*string);
            }
        }
        sr::GetJsonValue(json, "playbackmode", playbackmode);
        sr::GetJsonValue(json, "origin", origin, false);
        sr::GetJsonValue(json, "angles", angles, false);
        sr::GetJsonValue(json, "scale", scale, false);
        sr::GetJsonValue(json, "mintime", mintime, false);
        sr::GetJsonValue(json, "maxtime", maxtime, false);
        ReadVisibleProperty(json, visible, visible_user);
        visible_user_key = visible_user.name;
        sr::GetJsonValue(json, "name", name, false);
        sr::GetJsonValue(json, "id", id, false);
        sr::GetJsonValue(json, "locktransforms", locktransforms, false);
        sr::GetJsonValue(json, "muteineditor", muteineditor, false);
        sr::GetJsonValue(json, "nointerpolation", nointerpolation, false);
        sr::GetJsonValue(json, "parent", parent, false);
        sr::GetJsonValue(json, "dependencies", dependencies, false);
        if (auto value = json.get("instance"); value.is_some()) instance = (*value)->clone();

        sr::GetJsonValue(json, "startsilent", startsilent, false);
        sr::GetJsonValue(json, "blockalign", blockalign, false);
        sr::GetJsonValue(json, "spatialization", spatialization, false);
        sr::GetJsonValue(json, "queuemode", queuemode, false);

        auto sound_json = json.get("sound");
        if (sound_json.is_none()) return false;
        auto sound_array = (*sound_json)->as_array();
        if (sound_array.is_none()) return false;
        for (const auto& el : **sound_array) {
            std::string name;
            sr::GetJsonValue(el, name);
            if (! name.empty()) sound.push_back(name);
        }
        AbsorbAllFieldBindings(json, field_bindings);
        return true;
    }
};
} // namespace wpscene
} // namespace sr
