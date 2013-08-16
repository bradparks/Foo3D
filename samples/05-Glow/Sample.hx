package ;

import math.Mat44;
import Binary;
import Md2Parser;

import foo3D.utils.Frame;
import foo3D.RenderDevice;
import foo3D.RenderContext;
import haxe.ds.StringMap;

#if js
import UserAgentContext;
#end

typedef Hash<T> = StringMap<T>;



class Sample 
{
    static var rd:RenderDevice;
    static var base:SampleBase;

    static var playAnimation:Bool;
    static var showGlow:Bool;
    static var curFrame:Int = 0;    
    static var nextFrame:Int = 1;

    // matrices
    static var mProjOrtho:Mat44;
    static var mProjPersp:Mat44;
    static var mWorldMat:Mat44;

    // md2 model
    static var md2:Md2Model;
    static var md2VertLayout:Int;
    static var md2VBuffers:Array<Int>;
    static var md2IBuf:Int;
    static var md2UvBuf:Int;

    // textures
    static var texDiffuse:Int;
    static var texGlow:Int;

    // offscreen buffers
    static var glowSceneFBO:Int;
    static var glowBlurFBO:Int;

    // simple diffuse render
    static var diffuseProg:Int;
    static var diffuseLocs:Hash<UniformLocationType>;

    static var combineProg:Int;
    static var combineLocs:Hash<UniformLocationType>;
    
    // draw the blurred glowmap on a quad into the backbuffer
    static var blurProg:Int;
    static var blurLocs:Hash<UniformLocationType>;

    static function main() 
    {
        showGlow = true;
        playAnimation = false;

        base = new SampleBase();
        base.registerOnKeyDown(onKeyDown);

        Frame.onCtxCreated.add(onCtxCreated);
        Frame.onCtxLost.add(onCtxLost);
        Frame.onCtxUpdate.add(onCtxUpdate);        
        Frame.requestContext({name:"foo3D-stage", width:800, height:600});
    }

    static function onCtxCreated(_ctx:RenderContext):Void
    {
        // create device and basic settings
        rd = new RenderDevice(_ctx);
        rd.setViewport(0, 0, 800, 600);
        rd.setScissorRect(0, 0, 800, 600);

        // get us some cool default structures
        base.initDefaults(rd);

        // setup matrices
        mProjOrtho = Mat44.createOrthoLH(0, 1, 0, 1, -1, 1);
        mProjPersp = Mat44.createPerspLH(60, 800/600, 0.1, 100.0);
        mWorldMat = Mat44.createTranslation(0, -1, -7.5);
        mWorldMat.appendScale(0.1, 0.1, 0.1);

        // prep the model
        processMd2("blade_md2");

        // load the textures
        var texSrc:String = "../../Common/resources/tekkblade.png";
        texDiffuse = rd.createTexture(RDITextureTypes.TEX2D, 256, 256, RDITextureFormats.RGBA8, false, true);
        rd.uploadTextureData(texDiffuse, 0, 0, null);
        ImageLoader.loadImage(texSrc, function(_data:Dynamic):Void {
            rd.uploadTextureData(texDiffuse, 0, 0, _data);
        });
        
        texSrc = "../../Common/resources/fire.png";
        texGlow = rd.createTexture(RDITextureTypes.TEX2D, 512, 512, RDITextureFormats.RGBA8, false, true);
        rd.uploadTextureData(texGlow, 0, 0, null);        
        ImageLoader.loadImage(texSrc, function(_data:Dynamic):Void {
            rd.uploadTextureData(texGlow, 0, 0, _data);
        });
        
        // build the necessary programs
        diffuseProg = rd.createProgram(SampleShaders.vsMd2, SampleShaders.fsOneTex);
        rd.bindProgram(diffuseProg);
        diffuseLocs = new Hash<UniformLocationType>();
        diffuseLocs.set("viewProjMat", rd.getUniformLoc(diffuseProg, "viewProjMat"));
        diffuseLocs.set("worldMat", rd.getUniformLoc(diffuseProg, "worldMat"));
        diffuseLocs.set("interp", rd.getUniformLoc(diffuseProg, "interp"));
        diffuseLocs.set("time", rd.getUniformLoc(diffuseProg, "time"));
        diffuseLocs.set("tex", rd.getSamplerLoc(diffuseProg, "tex"));

        blurProg = rd.createProgram(SampleShaders.vsFsQuad, SampleShaders.fsBlurVertical);
        rd.bindProgram(blurProg);
        blurLocs = new Hash<UniformLocationType>();
        blurLocs.set("viewProjMat", rd.getUniformLoc(blurProg, "viewProjMat"));
        blurLocs.set("tex", rd.getSamplerLoc(blurProg, "tex"));

        combineProg = rd.createProgram(SampleShaders.vsFsQuad, SampleShaders.fsBlurHorizontal);
        rd.bindProgram(combineProg);
        combineLocs = new Hash<UniformLocationType>();
        combineLocs.set("viewProjMat", rd.getUniformLoc(combineProg, "viewProjMat"));
        combineLocs.set("tex", rd.getSamplerLoc(combineProg, "tex"));

        glowSceneFBO = rd.createRenderBuffer(512, 512, RDITextureFormats.RGBA8, true, 1, 0);
        glowBlurFBO = rd.createRenderBuffer(512, 512, RDITextureFormats.RGBA8, true, 1, 0);
    }

    static function onCtxLost(_ctx:RenderContext):Void
    {
        base.cleanUpDefaults(rd);

        for (i in md2VBuffers)
            rd.destroyBuffer(i);
        rd.destroyBuffer(md2UvBuf);
        rd.destroyBuffer(md2IBuf);

        rd.destroyTexture(texDiffuse);
        rd.destroyTexture(texGlow);

        rd.destroyProgram(diffuseProg);
        rd.destroyProgram(blurProg);
        rd.destroyProgram(combineProg);

        rd.destroyRenderBuffer(glowSceneFBO);
        rd.destroyRenderBuffer(glowBlurFBO);
    }

    static var rot:Float = 0;
    static var fpsTimer:Float = 0;
    static var animFPS:Float = 0.25;    
    static var scrollTimer:Float = 0;
    static var scrollFPS:Float = 1.0;

    static function onCtxUpdate(_):Void
    {
        // rotate the model
        rot += 10 * Frame.deltaTime;
        mWorldMat.recompose(
            math.Quat.rotateY(rot),
            math.Vec3.create(0.1, 0.1, 0.1),
            math.Vec3.create(0, -1, -7.5)
        );

        // animate the model
        var t:Float = 0;
        if (playAnimation)
        {
            fpsTimer += Frame.deltaTime;
            if (fpsTimer >= animFPS)
            {
                curFrame = (curFrame + 1 >= md2.header.numFrames) ? 0 : curFrame + 1;
                nextFrame = (nextFrame + 1 >= md2.header.numFrames) ? 0 : nextFrame + 1;
                fpsTimer -= animFPS;
            }
            t = fpsTimer/animFPS;
            if (t < 0) t = 0;
            if (t > 1) t = 1;
        }

        scrollTimer += Frame.deltaTime;
        if (scrollTimer >= scrollFPS)
            scrollTimer -= scrollFPS;

        var tmp:Float = scrollTimer/scrollFPS;

        if (showGlow) 
        {   
            // render model with glowmap to offscreen buffers and apply vertical blur
            rd.bindRenderBuffer(glowSceneFBO);
            rd.setViewport(0, 0, 512,  512);
            rd.clear(RDIClearFlags.ALL, 0, 0, 0);
            rd.bindProgram(diffuseProg);
            rd.setUniform(diffuseLocs.get("viewProjMat"), RDIShaderConstType.FLOAT44, mProjPersp.rawData);
            rd.setUniform(diffuseLocs.get("worldMat"), RDIShaderConstType.FLOAT44, mWorldMat.rawData);
            rd.setUniform(diffuseLocs.get("interp"), RDIShaderConstType.FLOAT, [t]);
            rd.setUniform(diffuseLocs.get("time"), RDIShaderConstType.FLOAT, [tmp]);
            rd.setSampler(diffuseLocs.get("tex"), 0);
            rd.setTexture(0, texGlow, RDISamplerState.FILTER_BILINEAR | RDISamplerState.ADDR_WRAP);
            rd.setVertexLayout(md2VertLayout);
            rd.setVertexBuffer(0, md2VBuffers[curFrame]);
            rd.setVertexBuffer(1, md2VBuffers[nextFrame]);
            rd.setVertexBuffer(2, md2UvBuf);
            rd.setIndexBuffer(md2IBuf);
            rd.setDepthFunc();
            rd.setBlendFunc(RDIBlendFactors.ONE, RDIBlendFactors.ZERO);
            rd.draw(RDIPrimType.TRIANGLES, md2.header.numTris * 3, 0);
            
            // blur quad
            rd.bindRenderBuffer(glowBlurFBO);
            rd.clear(RDIClearFlags.ALL, 0, 0, 0);
            rd.bindProgram(blurProg);
            rd.setUniform(blurLocs.get("viewProjMat"), RDIShaderConstType.FLOAT44, mProjOrtho.rawData);
            rd.setSampler(blurLocs.get("tex"), 0);
            rd.setTexture(0, rd.getRenderBufferTex(glowSceneFBO), RDISamplerState.FILTER_BILINEAR);
            rd.setVertexLayout(base.vlPosUv);
            rd.setVertexBuffer(0, base.vbFsQuad, 0, 5);
            rd.setIndexBuffer(base.ibFsQuad);
            rd.draw(RDIPrimType.TRIANGLES, 6, 0);
        }

        {
            // diffuse and final glowpass
            rd.bindRenderBuffer(0);
            rd.setViewport(0, 0, 800, 600);
            rd.clear(RDIClearFlags.ALL, 0, 0, 0.1);       
            rd.bindProgram(diffuseProg);
            rd.setUniform(diffuseLocs.get("viewProjMat"), RDIShaderConstType.FLOAT44, mProjPersp.rawData);
            rd.setUniform(diffuseLocs.get("worldMat"), RDIShaderConstType.FLOAT44, mWorldMat.rawData);
            rd.setUniform(diffuseLocs.get("interp"), RDIShaderConstType.FLOAT, [t]);
            rd.setUniform(diffuseLocs.get("time"), RDIShaderConstType.FLOAT, [0]);
            rd.setSampler(diffuseLocs.get("tex"), 0);
            rd.setTexture(0, texDiffuse, RDISamplerState.FILTER_BILINEAR);
            rd.setVertexLayout(md2VertLayout);
            rd.setVertexBuffer(0, md2VBuffers[curFrame]);
            rd.setVertexBuffer(1, md2VBuffers[nextFrame]);
            rd.setVertexBuffer(2, md2UvBuf);
            rd.setIndexBuffer(md2IBuf);
            rd.setDepthFunc();
            rd.setBlendFunc(RDIBlendFactors.ONE, RDIBlendFactors.ZERO);
            rd.draw(RDIPrimType.TRIANGLES, md2.header.numTris * 3, 0);

            if (showGlow)
            {
                // combine quad and apply horizontal blur
                rd.bindProgram(combineProg);
                rd.setUniform(combineLocs.get("viewProjMat"), RDIShaderConstType.FLOAT44, mProjOrtho.rawData);
                rd.setSampler(combineLocs.get("tex"), 0);
                rd.setTexture(0, rd.getRenderBufferTex(glowBlurFBO), RDISamplerState.FILTER_BILINEAR);
                rd.setVertexLayout(base.vlPosUv);
                rd.setVertexBuffer(0, base.vbFsQuad, 0, 5);
                rd.setIndexBuffer(base.ibFsQuad);
                rd.setDepthFunc(RDITestModes.DISABLE);
                rd.setBlendFunc(RDIBlendFactors.ONE, RDIBlendFactors.ONE);
                rd.draw(RDIPrimType.TRIANGLES, 6, 0);
            }
        }

    }

    static function onKeyDown(_evt:Dynamic):Void
    {
        switch(_evt.keyCode)
        {
            case 71: showGlow = !showGlow; // g
            case 65: playAnimation = !playAnimation; // a
        }
    }

    static function processMd2(_id:String):Void
    {
        // parse the modeldata
        md2 = Md2Parser.run(haxe.Resource.getBytes(_id));

        // move all frames into individual VBOs
        md2VBuffers = [];
        for (i in 0...md2.header.numFrames)
        {
            var f = md2.frames[i];            
            var verts:Array<Float> = [];
            for (j in 0...md2.header.numTris)
            {
                verts.push(f.verts[md2.triangles[j].vertInds[0]].x);
                verts.push(f.verts[md2.triangles[j].vertInds[0]].y);
                verts.push(f.verts[md2.triangles[j].vertInds[0]].z);

                verts.push(f.verts[md2.triangles[j].vertInds[1]].x);
                verts.push(f.verts[md2.triangles[j].vertInds[1]].y);
                verts.push(f.verts[md2.triangles[j].vertInds[1]].z);

                verts.push(f.verts[md2.triangles[j].vertInds[2]].x);
                verts.push(f.verts[md2.triangles[j].vertInds[2]].y);
                verts.push(f.verts[md2.triangles[j].vertInds[2]].z);
            }
            md2VBuffers.push(rd.createVertexBuffer(verts.length, verts, RDIBufferUsage.STATIC, 3));
        }
        // move the uvs into a VBO
        var uv:Array<Float> = [];
        for (i in 0...md2.header.numTris)
        {
            uv.push(md2.uv[md2.triangles[i].uvInds[0]].x);
            uv.push(md2.uv[md2.triangles[i].uvInds[0]].y);
            uv.push(md2.uv[md2.triangles[i].uvInds[1]].x);
            uv.push(md2.uv[md2.triangles[i].uvInds[1]].y);
            uv.push(md2.uv[md2.triangles[i].uvInds[2]].x);
            uv.push(md2.uv[md2.triangles[i].uvInds[2]].y);
        }
        // make a simple IBO
        var ind:Array<UInt> = [];
        for (i in 0...md2.header.numTris*3)
            ind.push(i);

        // register our layout
        md2VertLayout = rd.registerVertexLayout([
            new RDIVertexLayoutAttrib("vPosSrc", 0, 3, 0),
            new RDIVertexLayoutAttrib("vPosDst", 1, 3, 0),
            new RDIVertexLayoutAttrib("vUv", 2, 2, 0),
        ]);
        md2UvBuf = rd.createVertexBuffer(uv.length, uv, RDIBufferUsage.STATIC, 2);
        md2IBuf = rd.createIndexBuffer(ind.length, ind, RDIBufferUsage.STATIC);
    }
}