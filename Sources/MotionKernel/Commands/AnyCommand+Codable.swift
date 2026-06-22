import Foundation

extension AnyCommand.CompositionSetting {
    private enum CodingKeys: String, CodingKey { case key, value }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let key = try c.decode(String.self, forKey: .key)
        switch key {
        case "duration": self = .duration(try c.decode(TimeInterval.self, forKey: .value))
        case "fps": self = .fps(try c.decode(Double.self, forKey: .value))
        case "size": self = .size(try c.decode(Vec2.self, forKey: .value))
        case "backgroundColor": self = .backgroundColor(try c.decode(ColorValue.self, forKey: .value))
        case "name": self = .name(try c.decode(String.self, forKey: .value))
        default: throw CommandError.valueOutOfRange("unknown composition setting '\(key)'")
        }
    }
    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .duration(let d): try c.encode("duration", forKey: .key); try c.encode(d, forKey: .value)
        case .fps(let f): try c.encode("fps", forKey: .key); try c.encode(f, forKey: .value)
        case .size(let s): try c.encode("size", forKey: .key); try c.encode(s, forKey: .value)
        case .backgroundColor(let col): try c.encode("backgroundColor", forKey: .key); try c.encode(col, forKey: .value)
        case .name(let n): try c.encode("name", forKey: .key); try c.encode(n, forKey: .value)
        }
    }
}

extension AnyCommand {
    private enum CodingKeys: String, CodingKey {
        case type, layer, compId, layerId, sortKey, parentId
        case path, value, keyframe, t, easeIn, easeOut, moves
        case asset, assetId, setting, commands, label
        case visible, locked
        case pattern, params, layerIds, gap
        case effect, effectId, content, layerName
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "AddLayer":
            self = .addLayer(layer: try c.decode(Layer.self, forKey: .layer),
                             compId: try c.decode(EntityID.self, forKey: .compId))
        case "RemoveLayer":
            self = .removeLayer(layerId: try c.decode(EntityID.self, forKey: .layerId))
        case "ReorderLayer":
            self = .reorderLayer(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                 sortKey: try c.decode(SortKey.self, forKey: .sortKey))
        case "SetLayerVisible":
            self = .setLayerVisible(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                    visible: try c.decode(Bool.self, forKey: .visible))
        case "SetLayerLocked":
            self = .setLayerLocked(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                   locked: try c.decode(Bool.self, forKey: .locked))
        case "SetLayerParent":
            self = .setLayerParent(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                   parentId: try c.decodeIfPresent(EntityID.self, forKey: .parentId))
        case "SetProperty":
            self = .setProperty(path: try c.decode(String.self, forKey: .path),
                                value: try c.decode(AnyValue.self, forKey: .value))
        case "SetKeyframe":
            self = .setKeyframe(path: try c.decode(String.self, forKey: .path),
                                keyframe: try c.decode(AnyKeyframe.self, forKey: .keyframe))
        case "RemoveKeyframe":
            self = .removeKeyframe(path: try c.decode(String.self, forKey: .path),
                                   t: try c.decode(TimeInterval.self, forKey: .t))
        case "MoveKeyframes":
            self = .moveKeyframes(moves: try c.decode([KeyframeMove].self, forKey: .moves))
        case "SetKeyframeEasing":
            self = .setKeyframeEasing(path: try c.decode(String.self, forKey: .path),
                                      t: try c.decode(TimeInterval.self, forKey: .t),
                                      easeIn: try c.decodeIfPresent(ControlPoint.self, forKey: .easeIn),
                                      easeOut: try c.decodeIfPresent(ControlPoint.self, forKey: .easeOut))
        case "SetKeyframeInterp":
            self = .setKeyframeInterp(path: try c.decode(String.self, forKey: .path),
                                      t: try c.decode(TimeInterval.self, forKey: .t),
                                      interp: try Interpolation(from: decoder))
        case "AddAsset":
            self = .addAsset(asset: try c.decode(Asset.self, forKey: .asset))
        case "RemoveAsset":
            self = .removeAsset(assetId: try c.decode(EntityID.self, forKey: .assetId))
        case "AddEffect":
            self = .addEffect(layerId: try c.decode(EntityID.self, forKey: .layerId),
                              effect: try c.decode(Effect.self, forKey: .effect))
        case "RemoveEffect":
            self = .removeEffect(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                 effectId: try c.decode(EntityID.self, forKey: .effectId))
        case "SetLayerName":
            self = .setLayerName(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                 name: try c.decode(String.self, forKey: .layerName))
        case "SetContent":
            self = .setContent(layerId: try c.decode(EntityID.self, forKey: .layerId),
                               content: try c.decode(LayerContent.self, forKey: .content))
        case "SetCompositionSetting":
            self = .setCompositionSetting(compId: try c.decode(EntityID.self, forKey: .compId),
                                          setting: try c.decode(CompositionSetting.self, forKey: .setting))
        case "ApplyPattern":
            self = .applyPattern(layerId: try c.decode(EntityID.self, forKey: .layerId),
                                 pattern: try c.decode(MotionPattern.self, forKey: .pattern),
                                 params: try c.decode(PatternParams.self, forKey: .params))
        case "Stagger":
            self = .stagger(layerIds: try c.decode([EntityID].self, forKey: .layerIds),
                            pattern: try c.decode(MotionPattern.self, forKey: .pattern),
                            params: try c.decode(PatternParams.self, forKey: .params),
                            gap: try c.decodeIfPresent(TimeInterval.self, forKey: .gap) ?? 0.08)
        case "Batch":
            self = .batch(commands: try c.decode([AnyCommand].self, forKey: .commands),
                          label: try c.decodeIfPresent(String.self, forKey: .label) ?? "Batch")
        default:
            throw CommandError.unknownCommandType(type)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .addLayer(let layer, let compId):
            try c.encode("AddLayer", forKey: .type)
            try c.encode(layer, forKey: .layer)
            try c.encode(compId, forKey: .compId)
        case .removeLayer(let id):
            try c.encode("RemoveLayer", forKey: .type)
            try c.encode(id, forKey: .layerId)
        case .reorderLayer(let id, let sortKey):
            try c.encode("ReorderLayer", forKey: .type)
            try c.encode(id, forKey: .layerId)
            try c.encode(sortKey, forKey: .sortKey)
        case .setLayerVisible(let id, let visible):
            try c.encode("SetLayerVisible", forKey: .type)
            try c.encode(id, forKey: .layerId)
            try c.encode(visible, forKey: .visible)
        case .setLayerLocked(let id, let locked):
            try c.encode("SetLayerLocked", forKey: .type)
            try c.encode(id, forKey: .layerId)
            try c.encode(locked, forKey: .locked)
        case .setLayerParent(let id, let parentId):
            try c.encode("SetLayerParent", forKey: .type)
            try c.encode(id, forKey: .layerId)
            try c.encodeIfPresent(parentId, forKey: .parentId)
        case .setProperty(let path, let value):
            try c.encode("SetProperty", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(value, forKey: .value)
        case .setKeyframe(let path, let kf):
            try c.encode("SetKeyframe", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(kf, forKey: .keyframe)
        case .removeKeyframe(let path, let t):
            try c.encode("RemoveKeyframe", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(t, forKey: .t)
        case .moveKeyframes(let moves):
            try c.encode("MoveKeyframes", forKey: .type)
            try c.encode(moves, forKey: .moves)
        case .setKeyframeEasing(let path, let t, let easeIn, let easeOut):
            try c.encode("SetKeyframeEasing", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(t, forKey: .t)
            try c.encodeIfPresent(easeIn, forKey: .easeIn)
            try c.encodeIfPresent(easeOut, forKey: .easeOut)
        case .setKeyframeInterp(let path, let t, let interp):
            try c.encode("SetKeyframeInterp", forKey: .type)
            try c.encode(path, forKey: .path)
            try c.encode(t, forKey: .t)
            try interp.encode(to: encoder) // writes interp (+ spring)
        case .addAsset(let asset):
            try c.encode("AddAsset", forKey: .type)
            try c.encode(asset, forKey: .asset)
        case .removeAsset(let id):
            try c.encode("RemoveAsset", forKey: .type)
            try c.encode(id, forKey: .assetId)
        case .addEffect(let layerId, let effect):
            try c.encode("AddEffect", forKey: .type)
            try c.encode(layerId, forKey: .layerId)
            try c.encode(effect, forKey: .effect)
        case .removeEffect(let layerId, let effectId):
            try c.encode("RemoveEffect", forKey: .type)
            try c.encode(layerId, forKey: .layerId)
            try c.encode(effectId, forKey: .effectId)
        case .setLayerName(let layerId, let name):
            try c.encode("SetLayerName", forKey: .type)
            try c.encode(layerId, forKey: .layerId)
            try c.encode(name, forKey: .layerName)
        case .setContent(let layerId, let content):
            try c.encode("SetContent", forKey: .type)
            try c.encode(layerId, forKey: .layerId)
            try c.encode(content, forKey: .content)
        case .setCompositionSetting(let compId, let setting):
            try c.encode("SetCompositionSetting", forKey: .type)
            try c.encode(compId, forKey: .compId)
            try c.encode(setting, forKey: .setting)
        case .applyPattern(let layerId, let pattern, let params):
            try c.encode("ApplyPattern", forKey: .type)
            try c.encode(layerId, forKey: .layerId)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(params, forKey: .params)
        case .stagger(let layerIds, let pattern, let params, let gap):
            try c.encode("Stagger", forKey: .type)
            try c.encode(layerIds, forKey: .layerIds)
            try c.encode(pattern, forKey: .pattern)
            try c.encode(params, forKey: .params)
            try c.encode(gap, forKey: .gap)
        case .batch(let commands, let label):
            try c.encode("Batch", forKey: .type)
            try c.encode(commands, forKey: .commands)
            try c.encode(label, forKey: .label)
        }
    }
}
