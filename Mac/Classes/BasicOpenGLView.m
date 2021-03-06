
#import "BasicOpenGLView.h"
#import "GLCheck.h"
#import "trackball.h"
#import "drawinfo.h"

// ==================================

const GLfloat points[] = 
{
#import "values.inc"
};

recVec gOrigin = {0.0, 0.0, 0.0};

// single set of interaction flags and states
GLint gDollyPanStartPoint[2] = {0, 0};
GLfloat gTrackBallRotation [4] = {0.0f, 0.0f, 0.0f, 0.0f};
GLboolean gDolly = GL_FALSE;
GLboolean gPan = GL_FALSE;
GLboolean gTrackball = GL_FALSE;
BasicOpenGLView * gTrackingViewInfo = NULL;

// time and message info
CFAbsoluteTime gMsgPresistance = 10.0f;

// error output
GLString * gErrStringTex;
float gErrorTime;

// ==================================

#pragma mark ---- OpenGL Capabilities ----

// GL configuration info globals
// see GLCheck.h for more info
GLCaps * gDisplayCaps = NULL; // array of GLCaps
CGDisplayCount gNumDisplays = 0;

static void getCurrentCaps (void)
{
 	// Check for existing opengl caps here
	// This can be called again with same display caps array when display configurations are changed and
	//   your info needs to be updated.  Note, if you are doing dynmaic allocation, the number of displays
	//   may change and thus you should always reallocate your display caps array.
	if (gDisplayCaps && HaveOpenGLCapsChanged (gDisplayCaps, gNumDisplays)) { // see if caps have changed
		free (gDisplayCaps);
		gDisplayCaps = NULL;
	}
	if (!gDisplayCaps) { // if we do not have caps
		CheckOpenGLCaps (0, NULL, &gNumDisplays); // will just update number of displays
		gDisplayCaps = (GLCaps*) malloc (sizeof (GLCaps) * gNumDisplays);
		CheckOpenGLCaps (gNumDisplays, gDisplayCaps, &gNumDisplays);
		initCapsTexture (gDisplayCaps, gNumDisplays); // (re)init the texture for printing caps
	}
}

static void getColorComponents(NSColor *color, GLfloat *red, GLfloat *green, GLfloat *blue)
{
    NSColor *rgbColor = [color colorUsingColorSpaceName:NSCalibratedRGBColorSpace];
    *red = (GLfloat)[rgbColor redComponent];
    *green = (GLfloat)[rgbColor greenComponent];
    *blue = (GLfloat)[rgbColor blueComponent];
}

#pragma mark ---- Utilities ----

static CFAbsoluteTime gStartTime = 0.0f;

// set app start time
static void setStartTime (void)
{	
	gStartTime = CFAbsoluteTimeGetCurrent ();
}

// ---------------------------------

// return float elpased time in seconds since app start
static CFAbsoluteTime getElapsedTime (void)
{	
	return CFAbsoluteTimeGetCurrent () - gStartTime;
}

#pragma mark ---- Error Reporting ----

// error reporting as both window message and debugger string
void reportError (char * strError)
{
    NSMutableDictionary *attribs = [NSMutableDictionary dictionary];
    [attribs setObject: [NSFont fontWithName: @"Monaco" size: 9.0f] forKey: NSFontAttributeName];
    [attribs setObject: [NSColor whiteColor] forKey: NSForegroundColorAttributeName];

	gErrorTime = getElapsedTime ();
	NSString * errString = [NSString stringWithFormat:@"Error: %s (at time: %0.1f secs).", strError, gErrorTime];
	NSLog (@"%@\n", errString);
	if (gErrStringTex)
		[gErrStringTex setString:errString withAttributes:attribs];
	else {
		gErrStringTex = [[GLString alloc] initWithString:errString withAttributes:attribs withTextColor:[NSColor colorWithDeviceRed:1.0f green:1.0f blue:1.0f alpha:1.0f] withBoxColor:[NSColor colorWithDeviceRed:1.0f green:0.0f blue:0.0f alpha:0.3f] withBorderColor:[NSColor colorWithDeviceRed:1.0f green:0.0f blue:0.0f alpha:0.8f]];
	}
}

// ---------------------------------

// if error dump gl errors to debugger string, return error
GLenum glReportError (void)
{
	GLenum err = glGetError();
	if (GL_NO_ERROR != err)
		reportError ((char *) gluErrorString (err));
	return err;
}

#pragma mark ---- OpenGL Utils ----

// ---------------------------------

// ===================================

static NSOpenGLPixelFormat *GetOpenGLPixelFormat()
{
    // Antialised, hardware accelerated without fallback to the software renderer.
    
    NSOpenGLPixelFormatAttribute   attribsAntialised[] =
    {
        NSOpenGLPFAAccelerated,
        NSOpenGLPFANoRecovery,
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFAColorSize, 24,
        NSOpenGLPFAAlphaSize,  8,
        NSOpenGLPFAMultisample,
        NSOpenGLPFASampleBuffers, 1,
        NSOpenGLPFASamples, 4,
        0
    };
    
    NSOpenGLPixelFormat  *pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribsAntialised];
    
    if( pixelFormat == nil ) 
    {
        // If we can't get the desired pixel format then fewer attributes 
        // will be rerquested.
        
        NSOpenGLPixelFormatAttribute   attribsBasic[] =
        {
            NSOpenGLPFAAccelerated,
            NSOpenGLPFADoubleBuffer,
            NSOpenGLPFAColorSize, 24,
            NSOpenGLPFAAlphaSize,  8,
            0
        };
        
        pixelFormat = [[NSOpenGLPixelFormat alloc] initWithAttributes:attribsBasic];
        
        [[NSAlert alertWithMessageText:@"WARNING" 
                         defaultButton:@"Okay" 
                       alternateButton:nil 
                           otherButton:nil 
             informativeTextWithFormat:@"Basic pixel format was allocated!"] runModal];
    } // if
    
    return( pixelFormat );
} // GetOpenGLPixelFormat

@implementation BasicOpenGLView

@dynamic backgroundColor;
@dynamic foregroundColor;

// update the projection matrix based on camera and view info
- (void) updateProjection
{
	GLdouble ratio, radians, wd2;
	GLdouble left, right, top, bottom, near, far;

    [[self openGLContext] makeCurrentContext];

	// set projection
	glMatrixMode (GL_PROJECTION);
	glLoadIdentity ();
	near = -camera.viewPos.z - shapeSize * 0.5;
	if (near < 0.00001)
		near = 0.00001;
	far = -camera.viewPos.z + shapeSize * 0.5;
	if (far < 1.0)
		far = 1.0;
	radians = 0.0174532925 * camera.aperture / 2; // half aperture degrees to radians 
	wd2 = near * tan(radians);
	ratio = camera.viewWidth / (float) camera.viewHeight;
	if (ratio >= 1.0) {
		left  = -ratio * wd2;
		right = ratio * wd2;
		top = wd2;
		bottom = -wd2;	
	} else {
		left  = -wd2;
		right = wd2;
		top = wd2 / ratio;
		bottom = -wd2 / ratio;	
	}
	glFrustum (left, right, bottom, top, near, far);
	[self updateCameraString];
}

// ---------------------------------

// updates the contexts model view matrix for object and camera moves
- (void) updateModelView
{
    [[self openGLContext] makeCurrentContext];
	
	// move view
	glMatrixMode (GL_MODELVIEW);
	glLoadIdentity ();
	gluLookAt (camera.viewPos.x, camera.viewPos.y, camera.viewPos.z,
			   camera.viewPos.x + camera.viewDir.x,
			   camera.viewPos.y + camera.viewDir.y,
			   camera.viewPos.z + camera.viewDir.z,
			   camera.viewUp.x, camera.viewUp.y ,camera.viewUp.z);
			
	// if we have trackball rotation to map (this IS the test I want as it can be explicitly 0.0f)
	if ((gTrackingViewInfo == self) && gTrackBallRotation[0] != 0.0f) 
		glRotatef (gTrackBallRotation[0], gTrackBallRotation[1], gTrackBallRotation[2], gTrackBallRotation[3]);
	else {
	}
	// accumlated world rotation via trackball
	glRotatef (worldRotation[0], worldRotation[1], worldRotation[2], worldRotation[3]);
	// object itself rotating applied after camera rotation
	glRotatef (objectRotation[0], objectRotation[1], objectRotation[2], objectRotation[3]);
	rRot[0] = 0.0f; // reset animation rotations (do in all cases to prevent rotating while moving with trackball)
	rRot[1] = 0.0f;
	rRot[2] = 0.0f;
	[self updateCameraString];
}

// ---------------------------------

// handles resizing of GL need context update and if the window dimensions change, a
// a window dimension update, reseting of viewport and an update of the projection matrix
- (void) resizeGL
{
	NSRect rectView = [self bounds];
	
	// ensure camera knows size changed
	if ((camera.viewHeight != rectView.size.height) ||
	    (camera.viewWidth != rectView.size.width)) {
		camera.viewHeight = rectView.size.height;
		camera.viewWidth = rectView.size.width;
		
		glViewport (0, 0, camera.viewWidth, camera.viewHeight);
		[self updateProjection];  // update projection matrix
		[self updateInfoString];
	}
}

// ---------------------------------

// move camera in z axis
-(void)mouseDolly: (NSPoint) location
{
	GLfloat dolly = (gDollyPanStartPoint[1] -location.y) * -camera.viewPos.z / 300.0f;
	camera.viewPos.z += dolly;
	if (camera.viewPos.z == 0.0) // do not let z = 0.0
		camera.viewPos.z = 0.0001;
	gDollyPanStartPoint[0] = location.x;
	gDollyPanStartPoint[1] = location.y;
}
	
// ---------------------------------
	
// move camera in x/y plane
- (void)mousePan: (NSPoint) location
{
	GLfloat panX = (gDollyPanStartPoint[0] - location.x) / (900.0f / -camera.viewPos.z);
	GLfloat panY = (gDollyPanStartPoint[1] - location.y) / (900.0f / -camera.viewPos.z);
	camera.viewPos.x -= panX;
	camera.viewPos.y -= panY;
	gDollyPanStartPoint[0] = location.x;
	gDollyPanStartPoint[1] = location.y;
}

// ---------------------------------

// sets the camera data to initial conditions
- (void) resetCamera
{
   camera.aperture = 40;
   camera.rotPoint = gOrigin;

   camera.viewPos.x = 0.0;
   camera.viewPos.y = 0.0;
   camera.viewPos.z = -80.0;
   camera.viewDir.x = -camera.viewPos.x;
   camera.viewDir.y = -camera.viewPos.y;
   camera.viewDir.z = -camera.viewPos.z;

   camera.viewUp.x = 0;
   camera.viewUp.y = 1;
   camera.viewUp.z = 0;
}

// ---------------------------------

// given a delta time in seconds and current rotation accel, velocity and position, update overall object rotation
- (void) updateObjectRotationForTimeDelta:(CFAbsoluteTime)deltaTime
{
	// update rotation based on vel and accel
	float rotation[4] = {0.0f, 0.0f, 0.0f, 0.0f};
	GLfloat fVMax = 2.0;
	short i;
	// do velocities
	for (i = 0; i < 3; i++) {
		rVel[i] += rAccel[i] * deltaTime * 30.0;
		
		if (rVel[i] > fVMax) {
			rAccel[i] *= -1.0;
			rVel[i] = fVMax;
		} else if (rVel[i] < -fVMax) {
			rAccel[i] *= -1.0;
			rVel[i] = -fVMax;
		}
		
		rRot[i] += rVel[i] * deltaTime * 30.0;
		
		while (rRot[i] > 360.0)
			rRot[i] -= 360.0;
		while (rRot[i] < -360.0)
			rRot[i] += 360.0;
	}
	rotation[0] = rRot[0];
	rotation[1] = 1.0f;
	addToRotationTrackball (rotation, objectRotation);
	rotation[0] = rRot[1];
	rotation[1] = 0.0f; rotation[2] = 1.0f;
	addToRotationTrackball (rotation, objectRotation);
	rotation[0] = rRot[2];
	rotation[2] = 0.0f; rotation[3] = 1.0f;
	addToRotationTrackball (rotation, objectRotation);
}

// ---------------------------------

// per-window timer function, basic time based animation preformed here
- (void)animationTimer:(NSTimer *)timer
{
	BOOL shouldDraw = NO;
	if (fAnimate) {
		CFTimeInterval deltaTime = CFAbsoluteTimeGetCurrent () - time;
			
		if (deltaTime > 10.0) // skip pauses
			return;
		else {
			// if we are not rotating with trackball in this window
			if (!gTrackball || (gTrackingViewInfo != self)) {
				[self updateObjectRotationForTimeDelta: deltaTime]; // update object rotation
			}
			shouldDraw = YES; // force redraw
		}
	}
	time = CFAbsoluteTimeGetCurrent (); //reset time in all cases
	// if we have current messages
	if (((getElapsedTime () - msgTime) < gMsgPresistance) || ((getElapsedTime () - gErrorTime) < gMsgPresistance))
		shouldDraw = YES; // force redraw
	if (YES == shouldDraw) 
		[self drawRect:[self bounds]]; // redraw now instead dirty to enable updates during live resize
}

#pragma mark ---- Text Drawing ----

// these functions create or update GLStrings one should expect to have to regenerate the image, bitmap and texture when the string changes thus these functions are not particularly light weight

- (void) updateInfoString
{ // update info string texture
	NSString * string = [NSString stringWithFormat:@"(%0.0f x %0.0f) \n%s \n%s", [self bounds].size.width, [self bounds].size.height, glGetString (GL_RENDERER), glGetString (GL_VERSION)];
	if (infoStringTex)
		[infoStringTex setString:string withAttributes:stanStringAttrib];
	else {
		infoStringTex = [[GLString alloc] initWithString:string withAttributes:stanStringAttrib withTextColor:[NSColor colorWithDeviceRed:1.0f green:1.0f blue:1.0f alpha:1.0f] withBoxColor:[NSColor colorWithDeviceRed:0.5f green:0.5f blue:0.5f alpha:0.5f] withBorderColor:[NSColor colorWithDeviceRed:0.8f green:0.8f blue:0.8f alpha:0.8f]];
	}
}

// ---------------------------------

- (void) createHelpString
{
	NSString * string = [NSString stringWithFormat:@"Cmd-A: animate    Cmd-I: show info \n'h': toggle help    'c': toggle OpenGL caps"];
	helpStringTex = [[GLString alloc] initWithString:string withAttributes:stanStringAttrib withTextColor:[NSColor colorWithDeviceRed:1.0f green:1.0f blue:1.0f alpha:1.0f] withBoxColor:[NSColor colorWithDeviceRed:0.0f green:0.5f blue:0.0f alpha:0.5f] withBorderColor:[NSColor colorWithDeviceRed:0.3f green:0.8f blue:0.3f alpha:0.8f]];
}

// ---------------------------------

- (void) createMessageString
{
	NSString * string = [NSString stringWithFormat:@"No messages..."];
	msgStringTex = [[GLString alloc] initWithString:string withAttributes:stanStringAttrib withTextColor:[NSColor colorWithDeviceRed:1.0f green:1.0f blue:1.0f alpha:1.0f] withBoxColor:[NSColor colorWithDeviceRed:0.5f green:0.5f blue:0.5f alpha:0.5f] withBorderColor:[NSColor colorWithDeviceRed:0.8f green:0.8f blue:0.8f alpha:0.8f]];
}

// ---------------------------------

- (void) updateCameraString
{ // update info string texture
	static recCamera savedCamera; 
	
	// This is a compromise between a heavy comparison
	// and updating the camera texture when not needed
	// what is faster the comparison or the texture update
	// only empirical data on a particular configuration
	// will yield a real answer
	
	if  ( (savedCamera.viewPos.x == camera.viewPos.x) &&
		  (savedCamera.viewPos.y == camera.viewPos.y) &&
		  (savedCamera.viewPos.z == camera.viewPos.z) &&
		  (savedCamera.viewDir.x == camera.viewDir.x) &&
		  (savedCamera.viewDir.y == camera.viewDir.y) &&
		  (savedCamera.viewDir.z == camera.viewDir.z) &&
		  (savedCamera.aperture == camera.aperture) )
	{
		return; // Don't update texture! (which usually is more expensive than the comparison above)
	} else {
		NSString * string = [NSString stringWithFormat:@"Camera at (%0.1f, %0.1f, %0.1f) looking at (%0.1f, %0.1f, %0.1f) with %0.1f aperture", camera.viewPos.x, camera.viewPos.y, camera.viewPos.z, camera.viewDir.x, camera.viewDir.y, camera.viewDir.z, camera.aperture];
		if (camStringTex)
			[camStringTex setString:string withAttributes:stanStringAttrib];
		else {
			camStringTex = [[GLString alloc] initWithString:string withAttributes:stanStringAttrib withTextColor:[NSColor colorWithDeviceRed:1.0f green:1.0f blue:1.0f alpha:1.0f] withBoxColor:[NSColor colorWithDeviceRed:0.5f green:0.5f blue:0.5f alpha:0.5f] withBorderColor:[NSColor colorWithDeviceRed:0.8f green:0.8f blue:0.8f alpha:0.8f]];
		}
	}
	
	savedCamera = camera;
}

// ---------------------------------

// draw text info using our GLString class for much more optimized text drawing
- (void) drawInfo
{	
	GLint matrixMode;
	GLboolean depthTest = glIsEnabled (GL_DEPTH_TEST);
	GLfloat height, width, messageTop = 10.0f;
	
	height = camera.viewHeight;
	width = camera.viewWidth;
		
	// set orthograhic 1:1  pixel transform in local view coords
	glGetIntegerv (GL_MATRIX_MODE, &matrixMode);
	glMatrixMode (GL_PROJECTION);
	glPushMatrix();
		glLoadIdentity ();
		glMatrixMode (GL_MODELVIEW);
		glPushMatrix();
			glLoadIdentity ();
			glScalef (2.0f / width, -2.0f /  height, 1.0f);
			glTranslatef (-width / 2.0f, -height / 2.0f, 0.0f);
			
			glColor4f (1.0f, 1.0f, 1.0f, 1.0f);
			[infoStringTex drawAtPoint:NSMakePoint (10.0f, height - [infoStringTex frameSize].height - 10.0f)];
			[camStringTex drawAtPoint:NSMakePoint (10.0f, messageTop)];
			messageTop += [camStringTex frameSize].height + 3.0f;

			if (fDrawHelp)
				[helpStringTex drawAtPoint:NSMakePoint (floor ((width - [helpStringTex frameSize].width) / 2.0f), floor ((height - [helpStringTex frameSize].height) / 3.0f))];
			
			if (fDrawCaps) {
				GLint renderer;
				[[self pixelFormat] getValues:&renderer forAttribute:NSOpenGLPFARendererID forVirtualScreen:[[self openGLContext] currentVirtualScreen]];
				drawCaps (gDisplayCaps, gNumDisplays, renderer, width);
			}

			// message string
			float currTime = getElapsedTime ();
			if ((currTime - msgTime) < gMsgPresistance) {
				GLfloat comp = (gMsgPresistance - getElapsedTime () + msgTime) * 0.1; // premultiplied fade
				glColor4f (comp, comp, comp, comp);
				[msgStringTex drawAtPoint:NSMakePoint (10.0f, messageTop)];
				messageTop += [msgStringTex frameSize].height + 3.0f;
			}
			// global error message
			if ((currTime - gErrorTime) < gMsgPresistance) {
				GLfloat comp = (gMsgPresistance - getElapsedTime () + gErrorTime) * 0.1; // premultiplied fade
				glColor4f (comp, comp, comp, comp);
				[gErrStringTex drawAtPoint:NSMakePoint (10.0f, messageTop)];
			}

		// reset orginal martices
		glPopMatrix(); // GL_MODELVIEW
		glMatrixMode (GL_PROJECTION);
	glPopMatrix();
	glMatrixMode (matrixMode);

	glDisable (GL_TEXTURE_RECTANGLE_EXT);
	glDisable (GL_BLEND);
	if (depthTest)
		glEnable (GL_DEPTH_TEST);
	glReportError ();
}

#pragma mark -
#pragma mark IB Actions

- (IBAction)changePointSize:(id)sender
{
    pointSize = (GLfloat)[sender floatValue];
    [self drawRect:[self bounds]];
}

- (IBAction)printBitmap:(id)sender
{
    BOOL wasAnimating = fAnimate;
    if (wasAnimating)
    {
        // This will stop the animation
        [self animate:self];
    }

    NSSavePanel *savePanel = [NSSavePanel savePanel];
    [savePanel setRequiredFileType:@"tiff"];
    NSInteger result = [savePanel runModal];
    if (result == NSFileHandlingPanelOKButton)
    {
        NSURL *url = [savePanel URL];
        
        NSRect originalWindowFrame = [[self window] frame];
        NSRect originalFrame = [self frame];
        NSRect bigFrame = NSMakeRect(0.0, 0.0, 2000.0, 2000.0);
        NSWindow *bigWindow = [[NSWindow alloc] initWithContentRect:originalWindowFrame
                                                          styleMask:NSBorderlessWindowMask
                                                            backing:NSBackingStoreBuffered
                                                              defer:NO 
                                                             screen:nil];
        NSWindow *originalWindow = [self window];
        [[bigWindow contentView] addSubview:self];

//        GLdouble oldAperture = camera.aperture;
//        CGFloat factor = bigFrame.size.height / originalFrame.size.height;
//        camera.aperture = camera.aperture * factor;
//        [self updateProjection];

        [bigWindow setFrame:bigFrame display:YES];

        glReadBuffer(GL_FRONT);
        
        //Read OpenGL context pixels directly.
        
        // For extra safety, save & restore OpenGL states that are changed
        glPushClientAttrib(GL_CLIENT_PIXEL_STORE_BIT);
        
        glPixelStorei(GL_PACK_ALIGNMENT, 4); /* Force 4-byte alignment */
        glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        glPixelStorei(GL_PACK_SKIP_ROWS, 0);
        glPixelStorei(GL_PACK_SKIP_PIXELS, 0);
        
        mWidth = [self frame].size.width;
        mHeight = [self frame].size.height;
        
        mByteWidth = mWidth * 4;                // Assume 4 bytes/pixel for now
        mByteWidth = (mByteWidth + 3) & ~3;    // Align to 4 bytes
        
        mData = malloc(mByteWidth * mHeight);
        
        glReadPixels(0.0, 0.0, mWidth, mHeight, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, mData);
        
        [[originalWindow contentView] addSubview:self];
        [self setFrame:originalFrame];
//        camera.aperture = oldAperture;
//        [self updateProjection];
        [bigWindow release];
        
        [self drawRect:[self bounds]];
        
        [self createTIFFImageFile:url];
    }
    
    if (wasAnimating)
    {
        // This will restart the animation if required
        [self animate:self];
    }    
}

-(CGImageRef)createRGBImageFromBufferData
{
    CGColorSpaceRef cSpace = CGColorSpaceCreateWithName (kCGColorSpaceGenericRGB);
    NSAssert( cSpace != NULL, @"CGColorSpaceCreateWithName failure");
    
    CGContextRef bitmap = CGBitmapContextCreate(mData, mWidth, mHeight, 8, mByteWidth,
                                                cSpace,  
#if __BIG_ENDIAN__
                                                kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Big /* XRGB Big Endian */);
#else
    kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little /* XRGB Little Endian */);
#endif                                    
    NSAssert( bitmap != NULL, @"CGBitmapContextCreate failure");
    
    // Get rid of color space
    CFRelease(cSpace);
    
    // Make an image out of our bitmap; does a cheap vm_copy of the  
    // bitmap
    CGImageRef image = CGBitmapContextCreateImage(bitmap);
    NSAssert( image != NULL, @"CGBitmapContextCreate failure");
    
    // Get rid of bitmap
    CFRelease(bitmap);
    
    return image;
}


- (void)createTIFFImageFile:(NSURL *)url
{
    // glReadPixels writes things from bottom to top, but we
    // need a top to bottom representation, so we must flip
    // the buffer contents.
    [self flipImageData];
    
    // Create a Quartz image from our pixel buffer bits
    CGImageRef imageRef = [self createRGBImageFromBufferData];
    NSAssert( imageRef != 0, @"cgImageFromPixelBuffer failed");
    
    // Save the image to the file
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL((CFURLRef)url, CFSTR("public.tiff"), 1, nil);
    NSAssert( dest != 0, @"CGImageDestinationCreateWithURL failed");
    
    // Set the image in the image destination to be `image' with
    // optional properties specified in saved properties dict.
    CGImageDestinationAddImage(dest, imageRef, nil);
    
    bool success = CGImageDestinationFinalize(dest);
    NSAssert( success != 0, @"Image could not be written successfully");
    
    CFRelease(dest);
    CGImageRelease(imageRef);
}

- (void)flipImageData
{
    long top, bottom;
    void * buffer;
    void * topP;
    void * bottomP;
    void * base;
    long rowBytes;

 
    top = 0;
    bottom = mHeight - 1;
    base = mData;
    rowBytes = mByteWidth;
    buffer = malloc(rowBytes);
    NSAssert( buffer != nil, @"malloc failure");
    
    while ( top < bottom )
    {
        topP = (void *)((top * rowBytes) + (intptr_t)base);
        bottomP = (void *)((bottom * rowBytes) + (intptr_t)base);
        
        /*
         * Save and swap scanlines.
         *
         * This code does a simple in-place exchange with a temp buffer.
         * If you need to reformat the pixels, replace the first two bcopy()
         * calls with your own custom pixel reformatter.
         */
        bcopy( topP, buffer, rowBytes );
        bcopy( bottomP, topP, rowBytes );
        bcopy( buffer, bottomP, rowBytes );
        
        ++top;
        --bottom;
    }
    free( buffer );
}


- (IBAction)togglePointsAndLines:(id)sender
{
    if (drawType == GL_LINE_STRIP)
    {
        drawType = GL_POINTS;
        [pointLineSizeToolbarItem setLabel:@"Point Size"];
        [togglePointsAndLinesToolbarItem setLabel:@"Lines"];
        [togglePointsAndLinesToolbarItem setImage:[NSImage imageNamed:@"SnapBack.tiff"]];
    }
    else
    {
        drawType = GL_LINE_STRIP;
        [pointLineSizeToolbarItem setLabel:@"Line Width"];
        [togglePointsAndLinesToolbarItem setLabel:@"Points"];
        [togglePointsAndLinesToolbarItem setImage:[NSImage imageNamed:@"Linkback Green.tiff"]];
    }
    [self drawRect:[self bounds]];
}

- (IBAction)animate: (id) sender
{
	fAnimate = 1 - fAnimate;
	if (fAnimate)
    {
		[animateMenuItem setState: NSOnState];
        [playPauseToolbarItem setLabel:@"Pause"];
        NSImage *image = [NSImage imageNamed:@"Pause.tiff"];
        [playPauseToolbarItem setImage:image];
    }   
	else 
    {
		[animateMenuItem setState: NSOffState];
        [playPauseToolbarItem setLabel:@"Play"];
        NSImage *image = [NSImage imageNamed:@"Play.tiff"];
        [playPauseToolbarItem setImage:image];
    }
}

// ---------------------------------

- (IBAction)info: (id) sender
{
	fInfo = 1 - fInfo;
	if (fInfo)
		[infoMenuItem setState: NSOnState];
	else
		[infoMenuItem setState: NSOffState];
	[self setNeedsDisplay: YES];
}

- (IBAction)changeColor:(id)sender
{
    if (sender == foregroundColorWell)
    {
        self.foregroundColor = [sender color];
    }
    else if (sender == backgroundColorWell)
    {
        self.backgroundColor = [sender color];
    }
}

- (void)setForegroundColor:(NSColor *)newColor
{
    if (foregroundColor != newColor)
    {
        [foregroundColor release];
        foregroundColor = [newColor retain];
        
        [self setNeedsDisplay:YES];
    }
}

- (NSColor *)foregroundColor
{
    return foregroundColor;
}

- (void)setBackgroundColor:(NSColor *)newColor
{
    if (backgroundColor != newColor)
    {
        [backgroundColor release];
        backgroundColor = [newColor retain];
        
        GLfloat red, green, blue;
        getColorComponents(backgroundColor, &red, &green, &blue);
        glClearColor(red, green, blue, 0.0f);
        [self setNeedsDisplay:YES];
    }
}

- (NSColor *)backgroundColor
{
    return backgroundColor;
}

#pragma mark ---- Method Overrides ----

-(void)keyDown:(NSEvent *)theEvent
{
    NSString *characters = [theEvent characters];
    if ([characters length]) {
        unichar character = [characters characterAtIndex:0];
		switch (character) {
			case 'h':
				// toggle help
				fDrawHelp = 1 - fDrawHelp;
				[self setNeedsDisplay: YES];
				break;
			case 'c':
				// toggle caps
				fDrawCaps = 1 - fDrawCaps;
				[self setNeedsDisplay: YES];
				break;
		}
	}
}

// ---------------------------------

- (void)mouseDown:(NSEvent *)theEvent // trackball
{
    if ([theEvent modifierFlags] & NSControlKeyMask) // send to pan
		[self rightMouseDown:theEvent];
	else if ([theEvent modifierFlags] & NSAlternateKeyMask) // send to dolly
		[self otherMouseDown:theEvent];
	else {
		NSPoint location = [self convertPoint:[theEvent locationInWindow] fromView:nil];
		location.y = camera.viewHeight - location.y;
		gDolly = GL_FALSE; // no dolly
		gPan = GL_FALSE; // no pan
		gTrackball = GL_TRUE;
		startTrackball (location.x, location.y, 0, 0, camera.viewWidth, camera.viewHeight);
		gTrackingViewInfo = self;
	}
}

// ---------------------------------

- (void)rightMouseDown:(NSEvent *)theEvent // pan
{
	NSPoint location = [self convertPoint:[theEvent locationInWindow] fromView:nil];
	location.y = camera.viewHeight - location.y;
	if (gTrackball) { // if we are currently tracking, end trackball
		if (gTrackBallRotation[0] != 0.0)
			addToRotationTrackball (gTrackBallRotation, worldRotation);
		gTrackBallRotation [0] = gTrackBallRotation [1] = gTrackBallRotation [2] = gTrackBallRotation [3] = 0.0f;
	}
	gDolly = GL_FALSE; // no dolly
	gPan = GL_TRUE; 
	gTrackball = GL_FALSE; // no trackball
	gDollyPanStartPoint[0] = location.x;
	gDollyPanStartPoint[1] = location.y;
	gTrackingViewInfo = self;
}

// ---------------------------------

- (void)otherMouseDown:(NSEvent *)theEvent //dolly
{
	NSPoint location = [self convertPoint:[theEvent locationInWindow] fromView:nil];
	location.y = camera.viewHeight - location.y;
	if (gTrackball) { // if we are currently tracking, end trackball
		if (gTrackBallRotation[0] != 0.0)
			addToRotationTrackball (gTrackBallRotation, worldRotation);
		gTrackBallRotation [0] = gTrackBallRotation [1] = gTrackBallRotation [2] = gTrackBallRotation [3] = 0.0f;
	}
	gDolly = GL_TRUE;
	gPan = GL_FALSE; // no pan
	gTrackball = GL_FALSE; // no trackball
	gDollyPanStartPoint[0] = location.x;
	gDollyPanStartPoint[1] = location.y;
	gTrackingViewInfo = self;
}

// ---------------------------------

- (void)mouseUp:(NSEvent *)theEvent
{
	if (gDolly) { // end dolly
		gDolly = GL_FALSE;
	} else if (gPan) { // end pan
		gPan = GL_FALSE;
	} else if (gTrackball) { // end trackball
		gTrackball = GL_FALSE;
		if (gTrackBallRotation[0] != 0.0)
			addToRotationTrackball (gTrackBallRotation, worldRotation);
		gTrackBallRotation [0] = gTrackBallRotation [1] = gTrackBallRotation [2] = gTrackBallRotation [3] = 0.0f;
	} 
	gTrackingViewInfo = NULL;
}

// ---------------------------------

- (void)rightMouseUp:(NSEvent *)theEvent
{
	[self mouseUp:theEvent];
}

// ---------------------------------

- (void)otherMouseUp:(NSEvent *)theEvent
{
	[self mouseUp:theEvent];
}

// ---------------------------------

- (void)mouseDragged:(NSEvent *)theEvent
{
	NSPoint location = [self convertPoint:[theEvent locationInWindow] fromView:nil];
	location.y = camera.viewHeight - location.y;
	if (gTrackball) {
		rollToTrackball (location.x, location.y, gTrackBallRotation);
		[self setNeedsDisplay: YES];
	} else if (gDolly) {
		[self mouseDolly: location];
		[self updateProjection];  // update projection matrix (not normally done on draw)
		[self setNeedsDisplay: YES];
	} else if (gPan) {
		[self mousePan: location];
		[self setNeedsDisplay: YES];
	}
}

// ---------------------------------

- (void)scrollWheel:(NSEvent *)theEvent
{
	float wheelDelta = [theEvent deltaX] +[theEvent deltaY] + [theEvent deltaZ];
	if (wheelDelta)
	{
		GLfloat deltaAperture = wheelDelta * -camera.aperture / 200.0f;
		camera.aperture += deltaAperture;
		if (camera.aperture < 0.1) // do not let aperture <= 0.1
			camera.aperture = 0.1;
		if (camera.aperture > 179.9) // do not let aperture >= 180
			camera.aperture = 179.9;
		[self updateProjection]; // update projection matrix
		[self setNeedsDisplay: YES];
	}
}

// ---------------------------------

- (void)rightMouseDragged:(NSEvent *)theEvent
{
	[self mouseDragged: theEvent];
}

// ---------------------------------

- (void)otherMouseDragged:(NSEvent *)theEvent
{
	[self mouseDragged: theEvent];
}

// ---------------------------------

- (void) drawRect:(NSRect)rect
{		
	// setup viewport and prespective
	[self resizeGL]; // forces projection matrix update (does test for size changes)
	[self updateModelView];  // update model view matrix for object

	// clear our drawable
	glClear (GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	
	// model view and projection matricies already set

	[self drawScene];
    if (fInfo)
		[self drawInfo];
		
	if ([self inLiveResize] && !fAnimate)
		glFlush ();
	else
		[[self openGLContext] flushBuffer];
	glReportError ();
}

- (void)drawScene
{
    GLfloat red, green, blue;
    getColorComponents(foregroundColor, &red, &green, &blue);
    glColor3f(red, green, blue);
    
    glEnable(GL_MULTISAMPLE);
    glHint(GL_PERSPECTIVE_CORRECTION_HINT,GL_NICEST);
    
    if (drawType == GL_POINTS)
    {
        glHint (GL_POINT_SMOOTH_HINT, GL_NICEST);
        glEnable(GL_POINT_SMOOTH);
        glPointSize(pointSize);
    }
    else 
    {
        glHint (GL_LINE_SMOOTH_HINT, GL_NICEST);
        glEnable(GL_LINE_SMOOTH);
        glLineWidth(pointSize);
    }
    
    int points_count = (sizeof points) / (sizeof(GLfloat)) / 3;
    
    glVertexPointer(3, GL_FLOAT, 0, points);
    glEnableClientState(GL_VERTEX_ARRAY);
    glDrawArrays(drawType, 0, points_count);    
}

// ---------------------------------

// set initial OpenGL state (current context is set)
// called after context is created
- (void)prepareOpenGL
{
    const GLint swapInt = 1;

    [[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval]; // set to vbl sync

	// init GL stuff here
	glEnable(GL_DEPTH_TEST);

	glShadeModel(GL_SMOOTH);    
	glEnable(GL_CULL_FACE);
	glFrontFace(GL_CCW);
	glPolygonOffset (1.0f, 1.0f);
	
    GLfloat red, green, blue;
    getColorComponents(backgroundColor, &red, &green, &blue);
	glClearColor(red, green, blue, 0.0f);
	[self resetCamera];
	shapeSize = 120.0f; // max radius of of objects

	// init fonts for use with strings
	NSFont * font =[NSFont fontWithName:@"Helvetica" size:12.0];
	stanStringAttrib = [[NSMutableDictionary dictionary] retain];
	[stanStringAttrib setObject:font forKey:NSFontAttributeName];
	[stanStringAttrib setObject:[NSColor whiteColor] forKey:NSForegroundColorAttributeName];
	
	// ensure strings are created
	[self createHelpString];
	[self createMessageString];

}
// ---------------------------------

// this can be a troublesome call to do anything heavyweight, as it is called on window moves, resizes, and display config changes.  So be
// careful of doing too much here.
- (void) update // window resizes, moves and display changes (resize, depth and display config change)
{
    msgTime	= getElapsedTime ();
    [msgStringTex setString:[NSString stringWithFormat:@"update at %0.1f secs", msgTime]  withAttributes:stanStringAttrib];
	[super update];
	if (![self inLiveResize])  {// if not doing live resize
		[self updateInfoString]; // to get change in renderers will rebuld string every time (could test for early out)
		getCurrentCaps (); // this call checks to see if the current config changed in a reasonably lightweight way to prevent expensive re-allocations
	}
}

// ---------------------------------

-(id) initWithFrame: (NSRect) frameRect
{
	NSOpenGLPixelFormat * pf = GetOpenGLPixelFormat();

	self = [super initWithFrame: frameRect pixelFormat: pf];
    return self;
}

// ---------------------------------

- (BOOL)acceptsFirstResponder
{
  return YES;
}

// ---------------------------------

- (BOOL)becomeFirstResponder
{
  return  YES;
}

// ---------------------------------

- (BOOL)resignFirstResponder
{
  return YES;
}

// ---------------------------------

- (void) awakeFromNib
{
	setStartTime (); // get app start time
	getCurrentCaps (); // get current GL capabilites for all displays
	
	// set start values...
	rVel[0] = 0.3; rVel[1] = 0.1; rVel[2] = 0.2; 
	rAccel[0] = 0.003; rAccel[1] = -0.005; rAccel[2] = 0.004;
	fInfo = 0;
	fAnimate = 1;
	time = CFAbsoluteTimeGetCurrent ();  // set animation time start time
	fDrawHelp = 1;
    foregroundColor = [[NSColor orangeColor] retain];
    backgroundColor = [[NSColor blackColor] retain];
    
    drawType = GL_POINTS;
    pointSize = 1.0;

	// start animation timer
	timer = [NSTimer timerWithTimeInterval:(1.0f/60.0f) target:self selector:@selector(animationTimer:) userInfo:nil repeats:YES];
	[[NSRunLoop currentRunLoop] addTimer:timer forMode:NSDefaultRunLoopMode];
	[[NSRunLoop currentRunLoop] addTimer:timer forMode:NSEventTrackingRunLoopMode]; // ensure timer fires during resize
}


@end
