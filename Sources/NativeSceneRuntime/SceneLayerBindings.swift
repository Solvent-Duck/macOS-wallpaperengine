// Runtime-owned objects stay alive in QuickJS so a script can retain a layer
// reference across frames. Only declared properties are exchanged with Swift.
enum SceneLayerBindings {
    static let source = #"""
    (function() {
        const owners = Object.create(null);
        let layers = [];
        let changes = Object.create(null);
        const timelines = Object.create(null);
        const skeletalAnimations = Object.create(null);
        const textureAnimations = Object.create(null);
        const videoTextures = Object.create(null);
        const soundTransports = Object.create(null);
        const endedCallbacks = Object.create(null);
        const pendingEnded = Object.create(null);
        const dispatchedEndedFrames = Object.create(null);

        function makeTextureAnimation(config) {
            const state = Object.assign({}, config.state), object = {};
            function commit(action, value) {
                const response = globalThis.__weAnimationRequest(JSON.stringify({kind:'texture',key:config.key,action,
                    frame:action === 'setFrame' ? value : undefined,rate:action === 'rate' ? value : undefined}));
                Object.assign(state, response.state);
            }
            Object.defineProperties(object, {
                frameCount: {value:config.frameCount}, duration: {value:config.duration},
                rate: {get() { return state.rate; }, set(value) { if (Number.isFinite(value)) commit('rate',value); }},
                play: {value() { commit('play'); }}, pause: {value() { commit('pause'); }},
                stop: {value() { commit('stop'); }}, join: {value() { commit('join'); }},
                isPlaying: {value() { return state.playing; }}, getFrame: {value() { return state.frame; }},
                setFrame: {value(frame) { if (Number.isFinite(frame)) commit('setFrame',frame); }}
            });
            textureAnimations[config.key] = state;
            return object;
        }

        function videoTexture(key) {
            if (videoTextures[key]) return videoTextures[key].object;
            function request(action, value) {
                return globalThis.__weAnimationRequest(JSON.stringify({kind: 'video', key, action, value}));
            }
            const response = request('resolve');
            if (!response.state) return undefined;
            const state = response.state, object = {};
            function commit(action, value) { Object.assign(state, request(action, value).state); }
            Object.defineProperties(object, {
                duration: {get() { return state.duration; }},
                rate: {get() { return state.rate; }, set(value) { if (Number.isFinite(value)) commit('rate', value); }},
                loop: {get() { return state.loop; }, set(value) { commit('loop', Boolean(value)); }},
                play: {value() { commit('play'); }}, pause: {value() { commit('pause'); }},
                stop: {value() { commit('stop'); }}, isPlaying: {value() { return state.playing; }},
                getCurrentTime: {value() { return state.time; }},
                setCurrentTime: {value(value) { if (Number.isFinite(value)) commit('setCurrentTime', value); }},
                addEndedCallback: {value(callback) {
                    if (typeof callback !== 'function') throw new TypeError('Ended callback must be a function');
                    (endedCallbacks[key] ||= []).push({callback, instance: globalThis.__instanceID});
                }}
            });
            videoTextures[key] = {state, object};
            return object;
        }

        function addSkeletalPlayback(object, config) {
            const state = Object.assign({}, config.state);
            function commit(action, frame) {
                const response = globalThis.__weAnimationRequest(JSON.stringify({
                    kind: 'skeletal', key: config.key, action, frame, rate: object.rate
                }));
                Object.assign(state, response.state);
            }
            Object.defineProperties(object, {
                fps: {value: config.fps},
                frameCount: {value: config.frameCount},
                duration: {value: config.duration},
                play: {value() { commit('play'); }},
                pause: {value() { commit('pause'); }},
                stop: {value() { commit('stop'); }},
                isPlaying: {value() { return state.playing; }},
                getFrame: {value() { return state.frame; }},
                setFrame: {value(frame) { if (Number.isFinite(frame)) commit('setFrame', frame); }},
                addEndedCallback: {value(callback) {
                    if (typeof callback !== 'function') throw new TypeError('Ended callback must be a function');
                    (endedCallbacks[config.key] ||= []).push({callback, instance: globalThis.__instanceID});
                }}
            });
            skeletalAnimations[config.key] = state;
        }

        function addSoundTransport(object, config) {
            const state = {state: config.state, playing: config.state === 'playing', volume: config.gain};
            function commit(action, volume) {
                const response = globalThis.__weAnimationRequest(JSON.stringify({kind: 'sound', key: config.key, action, volume}));
                Object.assign(state, response.state);
                state.playing = state.state === 'playing';
            }
            soundTransports[config.key] = state;
            function storeVolume(value, publish = true) {
                if (!Number.isFinite(value)) return;
                const gain = Math.max(0, Math.min(1, value));
                if (publish) commit('volume', gain);
                else state.volume = gain;
            }
            Object.defineProperties(object, {
                play: {value() { commit('play'); }},
                pause: {value() { commit('pause'); }},
                stop: {value() { commit('stop'); }},
                isPlaying: {value() { return state.playing; }},
                volume: {enumerable: true, get() { return state.volume; }, set: storeVolume}
            });
            return storeVolume;
        }

        function addParticleTransport(object, key) {
            function request(action) {
                return globalThis.__weAnimationRequest(JSON.stringify({kind: 'particle', key, action}));
            }
            Object.defineProperties(object, {
                play: {value() { request('play'); }},
                pause: {value() { request('pause'); }},
                stop: {value() { request('stop'); }},
                // Query native liveness, including particles retained after pause.
                isPlaying: {value() { return request('isPlaying').playing; }}
            });
        }

        function makeAnimation(config, didChange) {
            const state = Object.assign({}, config.state);
            const object = {};
            function commit(sample = false) {
                const response = globalThis.__weAnimationRequest(JSON.stringify(Object.assign({key: config.key, sample}, state)));
                Object.assign(state, response.state);
                if ('value' in response) didChange(response.value);
            }
            function setFrame(frame) {
                if (!Number.isFinite(frame)) return;
                state.phase = Math.max(0, Math.min(config.length, frame));
                state.frame = config.mode === 'loop' && config.length > 0 ? state.phase % config.length : state.phase;
                commit(true);
            }
            Object.defineProperties(object, {
                fps: {value: config.fps},
                frameCount: {value: config.length},
                duration: {value: config.length / config.fps},
                name: {value: config.name},
                rate: {get() { return state.rate; }, set(value) {
                    if (Number.isFinite(value)) { state.rate = value; commit(); }
                }},
                play: {value() {
                    if (config.mode === 'single') {
                        if (state.rate > 0 && state.phase >= config.length) setFrame(0);
                        else if (state.rate < 0 && state.phase <= 0) setFrame(config.length);
                    }
                    state.playing = true;
                    commit();
                }},
                pause: {value() { state.playing = false; commit(); }},
                stop: {value() { state.playing = false; setFrame(0); }},
                isPlaying: {value() { return state.playing; }},
                getFrame: {value() { return state.frame; }},
                setFrame: {value: setFrame}
            });
            const timeline = {object, state, config};
            timelines[config.key] = timeline;
            return timeline;
        }

        function animationFor(owner, name) {
            if (!owner) return undefined;
            if (name !== undefined) return Object.values(owner.animations).find(entry => entry.config.name === name)?.object;
            const engine = globalThis.__engine;
            return engine?.__ownerID === owner.config.id ? owner.animations[engine.__property]?.object : undefined;
        }

        function materialFor(effect, index = 0) {
            if (!Number.isInteger(index) || index < 0 || !effect?.config.materials?.[index]) return undefined;
            const cache = effect.materials ||= [];
            if (cache[index]) return cache[index];
            const entries = effect.config.materials[index].map(id => owners[id]).filter(Boolean);
            const bindings = Object.create(null), object = {};
            // Scene overrides take precedence over authored material defaults.
            // Keep the original owners so scripts still initialize in their
            // established order and native descriptor identities stay intact.
            entries.forEach(entry => Object.keys(entry.config.keys).forEach(key => {
                if (!bindings[key]) bindings[key] = [];
                if (!bindings[key].some(target => target.config.id.includes('.override.')))
                    bindings[key].push(entry);
            }));
            Object.keys(bindings).forEach(key => {
                const targets = bindings[key];
                Object.defineProperty(object, key, {enumerable: true,
                    get() {
                        const value = targets[0].object[key];
                        if (targets.length < 2 || !value || typeof value !== 'object') return value;
                        return new Proxy(value, {set(_target, component, next) {
                            targets.forEach(owner => { if (!owner.disposed) owner.object[key][component] = next; });
                            return true;
                        }});
                    },
                    set(value) { targets.forEach(owner => { owner.object[key] = value; }); }
                });
            });
            Object.defineProperty(object, 'getAnimation', {value(name) {
                if (name === undefined) {
                    const engine = globalThis.__engine;
                    const target = bindings[engine?.__property]?.find(owner => owner.config.id === engine?.__ownerID);
                    return animationFor(target, name);
                }
                for (const [key, targets] of Object.entries(bindings)) {
                    for (const target of targets) {
                        const animation = target.animations[key];
                        if (animation?.config.name === name) return animation.object;
                    }
                }
                return undefined;
            }});
            cache[index] = object;
            return object;
        }

        function copy(value) {
            if (value === undefined || value === null) return value;
            if (Array.isArray(value)) return value.map(copy);
            if (typeof value === 'object') {
                const result = {};
                Object.keys(value).forEach(key => result[key] = copy(value[key]));
                return result;
            }
            return value;
        }

        function typed(value) {
            if (!value || typeof value !== 'object' || !('x' in value) || !('y' in value)) return value;
            // Constructors are installed before an authored script can read a layer.
            const Constructor = 'w' in value ? globalThis.Vec4 : ('z' in value ? globalThis.Vec3 : globalThis.Vec2);
            if (Constructor && !(value instanceof Constructor)) Object.setPrototypeOf(value, Constructor.prototype);
            return value;
        }

        function attachmentIndex(owner, reference) {
            const names = owner.config.attachments;
            if (typeof reference === 'string') return names.indexOf(reference);
            return Number.isInteger(reference) && reference >= 0 && reference < names.length ? reference : -1;
        }

        function attachmentLocal(owner, reference) {
            const index = attachmentIndex(owner, reference);
            if (index < 0) throw new RangeError('Unknown attachment: ' + reference);
            // Read live JS values so setFrame/visible/blend writes made by this
            // very callback affect the pose without waiting for a frame drain.
            const animationLayers = owner.config.skeletalLayers.map(id => {
                const object = owners[id].object;
                return {frame: object.getFrame(), visible: object.visible, blend: object.blend, rate: object.rate};
            });
            const result = new Mat4();
            result.m = globalThis.__weAttachmentRequest(JSON.stringify({id: owner.config.id, index, layers: animationLayers}));
            return result;
        }

        function worldTransform(owner, visiting = new Set()) {
            if (visiting.has(owner)) throw new RangeError('Cyclic layer hierarchy');
            visiting.add(owner);
            const object = owner.object;
            let result = Mat4.compose(object.origin ?? new Vec3(0), object.angles ?? new Vec3(0), object.scale ?? new Vec3(1));
            const parent = owners[owner.config.parent];
            if (parent) {
                const reference = owner.config.attachment;
                // Match renderer handling of unresolved authored attachments.
                if (reference !== null && reference !== undefined && attachmentIndex(parent, reference) >= 0)
                    result = attachmentLocal(parent, reference).multiply(result);
                result = worldTransform(parent, visiting).multiply(result);
            }
            visiting.delete(owner);
            return result;
        }

        function attachmentWorld(owner, reference) {
            const world = worldTransform(owner);
            return reference === undefined ? world : world.multiply(attachmentLocal(owner, reference));
        }

        function setParent(owner, reference, attachment, adjustTransforms) {
            if (typeof attachment === 'boolean') {
                adjustTransforms = attachment;
                attachment = undefined;
            }
            const parentObject = reference == null ? undefined : layer(reference);
            if (reference != null && !parentObject) throw new RangeError('Unknown parent layer');
            const parent = layers.find(entry => entry.object === parentObject);
            const visiting = new Set([owner]);
            for (let ancestor = parent; ancestor; ancestor = owners[ancestor.config.parent]) {
                if (visiting.has(ancestor)) throw new RangeError('Cyclic layer hierarchy');
                visiting.add(ancestor);
            }
            if (attachment != null && (!parent || attachmentIndex(parent, attachment) < 0))
                throw new RangeError('Unknown parent attachment');
            // Resolve and validate before changing either the hierarchy or the
            // local properties. A failed inverse must leave the layer intact.
            let transforms;
            if (adjustTransforms) {
                const previousWorld = worldTransform(owner);
                const parentWorld = parent ? attachmentWorld(parent, attachment ?? undefined) : new Mat4();
                transforms = parentWorld.inverse().multiply(previousWorld).decompose();
            }
            owner.config.parent = parent?.config.id ?? null;
            owner.config.attachment = attachment ?? null;
            (changes.__hierarchy ||= Object.create(null))[owner.config.id] = {
                parent: owner.config.parent, attachment: owner.config.attachment
            };
            if (transforms) {
                owner.object.origin = transforms.translation;
                owner.object.angles = transforms.rotation;
                owner.object.scale = transforms.scale;
            }
        }

        function makeOwner(config) {
            const values = Object.create(null);
            const object = {};
            const owner = {object, values, config, animations: Object.create(null)};
            owners[config.id] = owner;
            if (config.particleInstance) {
                Object.defineProperty(object, 'instance', {enumerable: true,
                    get() { return owners[config.particleInstance]?.object; }});
            }
            if (config.skeletalName !== null && config.skeletalName !== undefined) {
                Object.defineProperty(object, 'name', {enumerable: true, value: config.skeletalName});
            }
            if (config.skeletalPlayback) addSkeletalPlayback(object, config.skeletalPlayback);
            Object.keys(config.animations || {}).forEach(key => {
                owner.animations[key] = makeAnimation(config.animations[key], value => {
                    owner[key + ':store'](value, false);
                    if (config.keys[key]) delete changes[config.keys[key]];
                });
            });
            Object.defineProperty(object, 'getAnimation', {value(name) { return animationFor(owner, name); }});
            Object.keys(config.values).forEach(key => {
                function store(value, dirty) {
                    if (owner.disposed) return;
                    if (config.text && key === 'font') {
                        const asset = globalThis.__weAssetPath?.(value);
                        if (asset !== undefined) value = asset;
                    }
                    let next = copy(value);
                    if (next && typeof next === 'object' && 'x' in next && 'y' in next) {
                        // Component assignments such as layer.origin.x also reach Swift.
                        next = new Proxy(next, {
                            set(target, component, value) {
                                target[component] = value;
                                if (config.keys[key]) changes[config.keys[key]] = copy(next);
                                return true;
                            }
                        });
                    }
                    values[key] = next;
                    if (dirty && config.keys[key]) changes[config.keys[key]] = copy(next);
                }
                Object.defineProperty(object, key, {
                    enumerable: true,
                    get() { return typed(values[key]); },
                    set(value) { store(value, true); }
                });
                store(config.values[key], false);
                owner[key + ':store'] = store;
            });
            if (config.soundTransport) owner['volume:store'] = addSoundTransport(object, config.soundTransport);
            if (config.particleTransport) addParticleTransport(object, config.particleTransport);
            if (config.effects) {
                Object.defineProperties(object, {
                    getEffectCount: {value() { return config.effects.length; }},
                    getEffect: {value(reference) {
                        if (typeof reference === 'number')
                            return Number.isInteger(reference) ? owners[config.effects[reference]]?.object : undefined;
                        if (typeof reference === 'string')
                            return config.effects.map(id => owners[id]).find(entry => entry?.object.name === reference)?.object;
                        return undefined;
                    }}
                });
            }
            if (config.materials) {
                Object.defineProperties(object, {
                    getMaterialCount: {value() { return config.materials.length; }},
                    getMaterial: {value(index) { return materialFor(owner, index); }},
                    setMaterialProperty: {value(key, value) {
                        for (let index = 0; index < config.materials.length; index++) {
                            const material = materialFor(owner, index);
                            if (Object.prototype.hasOwnProperty.call(material, key) && key !== 'getAnimation') material[key] = value;
                        }
                    }}
                });
            }
            if (config.text) {
                Object.defineProperty(object, 'size', {enumerable: true, get() {
                    // Use live values: setters in this callback have not yet
                    // drained to Swift. Return a fresh, readonly-property Vec2.
                    const configuration = {
                        content: String(object.text ?? ''), fontPath: String(object.font),
                        pointSize: Number(object.pointsize), maxWidth: Number(object.maxwidth),
                        maxRows: Math.trunc(Number(object.maxrows)), padding: Math.trunc(Number(object.padding)),
                        horizontalAlign: String(object.horizontalalign), verticalAlign: String(object.verticalalign),
                        limitWidth: Boolean(object.limitwidth), limitRows: Boolean(object.limitrows),
                        limitUseEllipsis: Boolean(object.limituseellipsis), blockAlign: Boolean(object.blockalign)
                    };
                    return typed(globalThis.__weTextLayoutRequest(JSON.stringify({id: config.id, configuration})));
                }});
            }
            if (config.layer) {
                const textureAnimation = config.textureAnimation ? makeTextureAnimation(config.textureAnimation) : undefined;
                Object.defineProperties(object, {
                    getTextureAnimation: {value() { return textureAnimation; }},
                    getVideoTexture: {value() { return videoTexture(config.id); }},
                    getTransformMatrix: {value() { return worldTransform(owner); }},
                    getAttachmentIndex: {value(name) { return attachmentIndex(owner, name); }},
                    getAttachmentMatrix: {value(reference) { return attachmentWorld(owner, reference); }},
                    getAttachmentOrigin: {value(reference) { return attachmentWorld(owner, reference).translation(); }},
                    getAttachmentAngles: {value(reference) { return attachmentWorld(owner, reference).extractEuler(); }},
                    getAnimationLayerCount: {value() { return config.skeletalLayers.length; }},
                    getAnimationLayer: {value(name) {
                        const entries = config.skeletalLayers.map(id => owners[id]);
                        if (typeof name === 'number') return entries[name]?.object;
                        if (typeof name === 'string') return entries.find(entry => entry.object.name === name)?.object;
                        return undefined;
                    }},
                    getParent: {value() { return config.parent ? owners[config.parent]?.object : undefined; }},
                    setParent: {value(parent, attachment, adjustTransforms) { setParent(owner, parent, attachment, adjustTransforms); }},
                    getChildren: {value() {
                        return layers.filter(layer => layer.config.parent === config.id).map(layer => layer.object);
                    }}
                });
            }
            return owner;
        }

        const scene = {};
        function layer(value) {
            if (typeof value === 'number') return layers[value]?.object;
            if (typeof value === 'string') return layers.find(layer => layer.object.name === value)?.object;
            return layers.find(layer => layer.object === value)?.object;
        }
        function layerRequest(command) {
            return globalThis.__weSceneLayerRequest(JSON.stringify(command, (_key, value) => {
                if (value && typeof value === 'object' && typeof value.x === 'number' && typeof value.y === 'number'
                    && Object.keys(value).every(key => ['x','y','z','w'].includes(key))) {
                    return ['x','y','z','w'].filter(key => key in value).map(key => value[key]);
                }
                return value;
            }));
        }
        function layerOwner(reference) {
            const object = layer(reference);
            return layers.find(entry => entry.object === object);
        }
        Object.defineProperties(scene, {
            getAnimation: {value(name) { return animationFor(owners['scene.general'], name); }},
            getLayer: {value: layer},
            getLayerCount: {value() { return layers.length; }},
            enumerateLayers: {value() { return layers.map(layer => layer.object); }},
            getLayerIndex: {value(value) { return layers.findIndex(entry => entry.object === layer(value)); }},
            createLayer: {value(configuration) {
                const engine = globalThis.__weValueInstances?.[globalThis.__instanceID]?.module.engine ?? globalThis.__engine;
                const response = layerRequest({action:'create', configuration, workshopID:engine?.__assetNamespace?.()});
                const additions = response.owners.map(makeOwner);
                layers.push(...additions.filter(owner => owner.config.layer));
                return owners[response.id]?.object;
            }},
            getInitialLayerConfig: {value(reference) {
                const owner = layerOwner(reference);
                return owner ? layerRequest({action:'configuration', id:owner.config.id}).configuration : undefined;
            }},
            sortLayer: {value(reference, index) {
                const owner = layerOwner(reference);
                if (!owner || !Number.isInteger(index)) return false;
                const target = Math.max(0, Math.min(index, layers.length - 1));
                if (!layerRequest({action:'sort', id:owner.config.id, index:target}).result) return false;
                layers.splice(layers.indexOf(owner), 1); layers.splice(target, 0, owner);
                return true;
            }},
            destroyLayer: {value(reference) {
                const owner = layerOwner(reference);
                return !!owner && layerRequest({action:'destroy', id:owner.config.id}).result;
            }}
        });
        globalThis.thisScene = scene;
        globalThis.__weSceneLayer = id => {
            const owner = owners[id];
            return owner?.config.layerID ? owners[owner.config.layerID]?.object : owner?.object;
        };
        globalThis.__weSceneObject = id => {
            if (id === 'scene.general') return scene;
            const owner = owners[id], view = owner?.config.materialView;
            return view ? materialFor(owners[view.effect], view.index) : owner?.object;
        };
        // Shared functions and classes execute for their caller. Capturing
        // these globals in the library's wrapper would bind every call to the
        // library layer. Authored `const saved = thisLayer` still keeps a real
        // stable object reference, including across timer callbacks.
        let fallbackLayer, fallbackObject;
        Object.defineProperties(globalThis, {
            thisLayer: {configurable: true,
                get() { return globalThis.__weSceneLayer(globalThis.__engine?.__ownerID) ?? fallbackLayer; },
                set(value) { fallbackLayer = value; }},
            thisObject: {configurable: true,
                get() { return globalThis.__weSceneObject(globalThis.__engine?.__ownerID) ?? fallbackObject; },
                set(value) { fallbackObject = value; }}
        });
        globalThis.__weSetSoundTransports = function(updates) {
            Object.keys(updates || {}).forEach(key => {
                const state = soundTransports[key];
                if (!state) return;
                Object.assign(state, updates[key]);
                state.playing = state.state === 'playing';
            });
        };
        globalThis.__weDrainSceneMutations = function() {
            const result = changes;
            changes = Object.create(null);
            return result;
        };
        function cursorGeometry(owner, position) {
            if (!owner?.config.cursorEnabled || owner.disposed) return null;
            const visited = new Set();
            for (let current = owner; current; current = owners[current.config.parent]) {
                if (visited.has(current) || current.disposed || current.object.visible === false) return null;
                visited.add(current);
            }
            const object = owner.object, size = object.size;
            if (!(size?.x > 0 && size?.y > 0)) return null;
            const m = worldTransform(owner).m;
            // Invert the projected 2D basis, including parent transforms. A
            // zero-scale or edge-on layer has no clickable area.
            const determinant = m[0] * m[5] - m[1] * m[4];
            if (!Number.isFinite(determinant) || Math.abs(determinant) < 1e-12) return null;
            const x = position.x - m[12], y = position.y - m[13];
            const point = new Vec3((x * m[5] - y * m[4]) / determinant,
                (y * m[0] - x * m[1]) / determinant, 0);
            let left = -size.x / 2, bottom = -size.y / 2;
            if (owner.config.text) {
                const padding = Math.max(0, Number(object.padding) || 0);
                const horizontal = String(object.horizontalalign).toLowerCase();
                const vertical = String(object.verticalalign).toLowerCase();
                if (horizontal === 'left') left = -padding;
                else if (horizontal === 'right') left = -size.x + padding;
                if (vertical === 'bottom') bottom = -padding;
                else if (vertical === 'top') bottom = -size.y + padding;
            } else {
                const alignment = String(object.alignment ?? 'center').toLowerCase();
                if (alignment.includes('left')) left = 0;
                else if (alignment.includes('right')) left = -size.x;
                if (alignment.includes('bottom')) bottom = 0;
                else if (alignment.includes('top')) bottom = -size.y;
            }
            const local = new Vec3(point.x - left, point.y - bottom, 0);
            return {inside: local.x >= 0 && local.x <= size.x && local.y >= 0 && local.y <= size.y,
                localPosition: local, worldPosition: new Vec3(position.x, position.y, 0)};
        }
        function dispatchCursorSample(state, module, input, sampleIndex) {
            const frame = module.engine.frameIndex;
            const binding = owners[globalThis.__engine.__ownerID];
            const owner = binding?.config.layerID ? owners[binding.config.layerID] : binding;
            const present = !!input.__hasCursor, down = present && !!input.cursorLeftDown;
            const position = input.cursorWorldPosition;
            const previous = state.cursor;
            if (module.engine.isPaused) {
                state.cursor = {x: position.x, y: position.y, down, inside: false, pressed: false};
                return;
            }
            // All modules on the same layer receive the same pre-callback hit,
            // even if an earlier property callback moves or hides the layer.
            if (owner && (frame === undefined || owner.cursorFrame !== frame)) {
                owner.cursorFrame = frame;
                owner.cursorGeometries = [];
            }
            if (owner && !(sampleIndex in owner.cursorGeometries)) {
                owner.cursorGeometries[sampleIndex] = present ? cursorGeometry(owner, position) : null;
            }
            const geometry = owner?.cursorGeometries?.[sampleIndex], inside = !!geometry?.inside;
            const moved = present && previous && (position.x !== previous.x || position.y !== previous.y);
            const pressed = !!previous?.pressed;
            state.cursor = {x: position.x, y: position.y, down, inside,
                pressed: geometry && down && (pressed || (!previous?.down && inside)),
                event: geometry || previous?.event};
            const events = [];
            if (previous?.inside && !inside) events.push('cursorLeave');
            if (!previous?.inside && inside) events.push('cursorEnter');
            // Move is global for an interactive layer, allowing fast drags to
            // continue even when the pointer leaves its old bounds.
            if (geometry && moved) events.push('cursorMove');
            if (geometry && inside && down && !previous?.down) events.push('cursorDown');
            if (previous?.down && (!down || !geometry) && (inside || pressed)) {
                events.push('cursorUp');
                if (inside && pressed && !down) events.push('cursorClick');
            }
            const event = geometry || previous?.event;
            let firstError, didThrow = false;
            for (const name of events) {
                if (!event || !module.cursorCallbacks[name]) continue;
                try {
                    module.cursorCallbacks[name]({worldPosition: new Vec3(event.worldPosition),
                        localPosition: new Vec3(event.localPosition)});
                } catch (error) { if (!didThrow) { firstError = error; didThrow = true; } }
            }
            if (didThrow) throw firstError;
        }
        globalThis.__weDispatchCursor = function(state, module) {
            const frame = module.engine.frameIndex, input = module.input;
            const pending = input.__cursorEvents || [];
            if (!input.__hasCursor && !state.cursor && !pending.length) return;
            if (frame !== undefined && state.cursorFrame === frame) return;
            state.cursorFrame = frame;
            const keys = ['__hasCursor', 'cursorPosition', 'cursorWorldPosition', 'cursorScreenPosition', 'cursorLeftDown'];
            const current = {};
            for (const key of keys) current[key] = input[key];
            const samples = !module.engine.isPaused && pending.length ? pending : [current];
            let firstError, didThrow = false;
            function remember(error) { if (!didThrow) { firstError = error; didThrow = true; } }
            try {
                if (input.__resetCursorEvents || module.engine.isPaused) {
                    // Cancel authored drag state without synthesizing a click.
                    const previous = state.cursor;
                    if (previous?.pressed && previous.event && module.cursorCallbacks.cursorUp) {
                        input.cursorLeftDown = false;
                        try {
                            module.cursorCallbacks.cursorUp({worldPosition: new Vec3(previous.event.worldPosition),
                                localPosition: new Vec3(previous.event.localPosition)});
                        } catch (error) { remember(error); }
                    }
                    const first = samples[0];
                    state.cursor = {x: first.cursorWorldPosition.x, y: first.cursorWorldPosition.y,
                        down: !!first.cursorLeftDown, inside: false, pressed: false};
                }
                for (let index = 0; index < samples.length; index++) {
                    const sample = samples[index];
                    for (const key of keys) input[key] = sample[key];
                    try { dispatchCursorSample(state, module, input, index); }
                    catch (error) { remember(error); }
                }
            } finally {
                // update() and shader/parallax inputs retain the latest sample.
                for (const key of keys) input[key] = current[key];
            }
            if (didThrow) throw firstError;
        };
        globalThis.__weDispatchAnimationCallbacks = function(instance, frame) {
            const queue = pendingEnded[instance];
            if (!queue?.length || (frame !== undefined && dispatchedEndedFrames[instance] === frame)) return;
            dispatchedEndedFrames[instance] = frame;
            // Keep a compact backlog when an extreme rate or elapsed interval
            // crosses many ends, without blocking a frame on unbounded calls.
            let budget = 1024, firstError, didThrow = false;
            while (queue.length && budget-- > 0) {
                const batch = queue[0];
                const callback = batch.callbacks[batch.index++];
                if (batch.index === batch.callbacks.length) {
                    batch.index = 0;
                    if (--batch.count <= 0) queue.shift();
                }
                try { callback(); } catch (error) {
                    if (!didThrow) { firstError = error; didThrow = true; }
                }
            }
            if (didThrow) throw firstError;
        };
        globalThis.__weClearAnimationCallbacks = function() {
            [endedCallbacks, pendingEnded, dispatchedEndedFrames].forEach(map => Object.keys(map).forEach(key => delete map[key]));
        };
        globalThis.__weSceneBridge = function(command) {
            if (command.removeLayers) {
                const belongs = key => command.removeLayers.some(id => key === id || key.startsWith(id + '.'));
                const instances = globalThis.__weValueInstances || {};
                const previousEngine = globalThis.__engine, previousInstance = globalThis.__instanceID;
                let firstError;
                Object.keys(instances).filter(belongs).forEach(key => {
                    const state = instances[key];
                    delete instances[key];
                    globalThis.__engine = state.module.engine;
                    globalThis.__instanceID = key;
                    try { if (state.initialized && state.module.destroy) state.module.destroy(); }
                    catch (error) { if (!firstError) firstError = error; }
                });
                globalThis.__engine = previousEngine; globalThis.__instanceID = previousInstance;
                Object.keys(owners).filter(belongs).forEach(id => {
                    owners[id].disposed = true;
                    delete owners[id];
                });
                layers = layers.filter(owner => !belongs(owner.config.id));
                layers.forEach(owner => { if (owner.config.parent && belongs(owner.config.parent)) owner.config.parent = null; });
                [timelines, skeletalAnimations, textureAnimations, videoTextures, soundTransports,
                 endedCallbacks, pendingEnded, dispatchedEndedFrames, changes].forEach(map => {
                    Object.keys(map).filter(belongs).forEach(key => delete map[key]);
                });
                if (firstError) throw firstError;
            }
            if (command.textureAnimations) Object.keys(command.textureAnimations).forEach(key => {
                if (textureAnimations[key]) Object.assign(textureAnimations[key], command.textureAnimations[key]);
            });
            if (command.videoTextures) Object.keys(command.videoTextures).forEach(key => {
                if (videoTextures[key]) Object.assign(videoTextures[key].state, command.videoTextures[key]);
            });
            if (command.skeletalAnimations) Object.keys(command.skeletalAnimations).forEach(key => {
                if (skeletalAnimations[key]) Object.assign(skeletalAnimations[key], command.skeletalAnimations[key]);
            });
            if (command.soundTransports) globalThis.__weSetSoundTransports(command.soundTransports);
            const ended = Object.assign({}, command.skeletalEnded, command.videoEnded);
            Object.keys(ended).forEach(key => {
                const count = ended[key];
                if (!(count > 0) || !Number.isFinite(count)) return;
                const grouped = Object.create(null);
                // Snapshot registrations at the crossing. A callback added
                // during dispatch starts with the next clock interval.
                (endedCallbacks[key] || []).forEach(entry => (grouped[entry.instance] ||= []).push(entry.callback));
                Object.keys(grouped).forEach(instance => {
                    (pendingEnded[instance] ||= []).push({count, callbacks: grouped[instance], index: 0});
                });
            });
            if (command.animations) Object.keys(command.animations).forEach(key => {
                if (timelines[key]) Object.assign(timelines[key].state, command.animations[key]);
            });
            if (command.owners) {
                layers = command.owners.map(makeOwner).filter(owner => owner.config.layer);
                const general = owners['scene.general'];
                if (general) Object.keys(general.config.values).forEach(key => {
                    Object.defineProperty(scene, key, Object.getOwnPropertyDescriptor(general.object, key));
                });
            }
            if (command.values) Object.keys(command.values).forEach(id => {
                const owner = owners[id];
                if (!owner) return;
                Object.keys(command.values[id]).forEach(key => {
                    const store = owner[key + ':store'];
                    if (store) store(command.values[id][key], false);
                });
            });
            return null;
        };
    })();
    """#
}
