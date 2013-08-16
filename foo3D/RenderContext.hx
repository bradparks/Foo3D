package foo3D;

#if js

import UserAgentContext;

typedef RenderContext = WebGLRenderingContext;

#elseif (flash || nme)

typedef RenderContext = flash.display3D.Context3D;

#elseif cpp

typedef RenderContext = Null<Int>;

#end