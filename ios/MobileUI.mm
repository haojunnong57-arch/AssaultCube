// MobileUI.mm — native iOS control layer for AssaultCube.
//
// Why a native layer instead of the upstream OpenGL touch HUD:
//   * the upstream HUD icons are drawn into the GL scene through gl4es and were
//     invisible on iPhone Air / iOS 27;
//   * UIKit gives real Liquid Glass materials, real 44pt hit targets and text;
//   * a native layer can forward hardware keyboard/mouse and rebind keys.
//
// The layer only owns the areas it actually draws: everything else falls through
// to SDL, so the engine keeps handling look-drag and pinch-free camera control.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <SDL.h>
#include <SDL_syswm.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <dispatch/dispatch.h>

extern "C" {
    void ac_ios_key(int code, int down);
    void ac_ios_key_force(int code, int down);
    int  ac_ios_exec(const char *cmd);
    extern int ac_ios_input_blocked;
}

// Engine-side queries (C++ linkage, defined in touch/touch.cpp).
extern bool touchmenuvisible();
extern bool touchenabled();

#pragma mark - Small helpers

static NSString *const kShowControls = @"ac.showControls";
static NSString *const kLeftHanded   = @"ac.leftHanded";
static NSString *const kButtonScale  = @"ac.buttonScale";
static NSString *const kControlAlpha = @"ac.controlAlpha";
static NSString *const kSensitivity  = @"ac.sensitivity";
static NSString *const kButtonCodes  = @"ac.buttonCodes";
static NSString *const kKeyBindings  = @"ac.keyBindings";

static UIColor *ACWhite(CGFloat alpha) { return [UIColor colorWithWhite:1.0 alpha:alpha]; }

// UIGlassEffect is iOS 26+. Resolve it at runtime so the binary still builds
// against older SDKs and still ships when the effect is unavailable.
static UIVisualEffect *ACGlassEffect(void)
{
    static UIVisualEffect *cached = nil;
    if (cached) return cached;

    Class glassClass = NSClassFromString(@"UIGlassEffect");
    SEL factory = NSSelectorFromString(@"effectWithStyle:");
    if (glassClass && [glassClass respondsToSelector:factory]) {
        NSMethodSignature *sig = [glassClass methodSignatureForSelector:factory];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            [inv setTarget:glassClass];
            [inv setSelector:factory];
            NSInteger style = 0; // regular glass
            [inv setArgument:&style atIndex:2];
            [inv invoke];
            __unsafe_unretained id obj = nil;
            [inv getReturnValue:&obj];
            if (obj) cached = (UIVisualEffect *)obj;
        }
    }
    if (!cached) cached = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    return cached;
}

// Glass surface = system material + refraction-ish rim + specular top highlight.
@interface ACGlassView : UIView
@property (nonatomic, strong) UIVisualEffectView *effectView;
@property (nonatomic, strong) CAGradientLayer *rim;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@property (nonatomic, strong) CAGradientLayer *highlight;
@property (nonatomic) CGFloat glassRadius;
@end

@implementation ACGlassView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;

        _effectView = [[UIVisualEffectView alloc] initWithEffect:ACGlassEffect()];
        _effectView.userInteractionEnabled = NO;
        _effectView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_effectView];

        _rim = [CAGradientLayer layer];
        _rim.colors = @[(__bridge id)ACWhite(0.55).CGColor,
                        (__bridge id)ACWhite(0.10).CGColor,
                        (__bridge id)ACWhite(0.32).CGColor];
        _rim.locations = @[@0.0, @0.55, @1.0];
        _rim.startPoint = CGPointMake(0.05, 0.0);
        _rim.endPoint = CGPointMake(0.95, 1.0);
        _rimMask = [CAShapeLayer layer];
        _rimMask.fillColor = UIColor.clearColor.CGColor;
        _rimMask.strokeColor = UIColor.whiteColor.CGColor;
        _rimMask.lineWidth = 1.15;
        _rim.mask = _rimMask;
        [self.layer addSublayer:_rim];

        _highlight = [CAGradientLayer layer];
        _highlight.colors = @[(__bridge id)ACWhite(0.30).CGColor,
                              (__bridge id)ACWhite(0.04).CGColor,
                              (__bridge id)UIColor.clearColor.CGColor];
        _highlight.locations = @[@0.0, @0.45, @1.0];
        [self.layer addSublayer:_highlight];

        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 14.0;
        self.layer.shadowOffset = CGSizeMake(0, 7);

        NSLayoutConstraint *w = [NSLayoutConstraint constraintWithItem:_effectView attribute:NSLayoutAttributeWidth relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeWidth multiplier:1.0 constant:0];
        NSLayoutConstraint *h = [NSLayoutConstraint constraintWithItem:_effectView attribute:NSLayoutAttributeHeight relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeHeight multiplier:1.0 constant:0];
        NSLayoutConstraint *cx = [NSLayoutConstraint constraintWithItem:_effectView attribute:NSLayoutAttributeCenterX relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterX multiplier:1.0 constant:0];
        NSLayoutConstraint *cy = [NSLayoutConstraint constraintWithItem:_effectView attribute:NSLayoutAttributeCenterY relatedBy:NSLayoutRelationEqual toItem:self attribute:NSLayoutAttributeCenterY multiplier:1.0 constant:0];
        [NSLayoutConstraint activateConstraints:@[w, h, cx, cy]];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    self.glassRadius = self.glassRadius > 0 ? self.glassRadius : MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds)) * 0.5;
    CGFloat radius = self.glassRadius;

    _effectView.layer.cornerRadius = radius;
    _effectView.layer.cornerCurve = kCACornerCurveContinuous;
    _effectView.layer.masksToBounds = YES;

    _rim.frame = self.bounds;
    _rim.cornerRadius = radius;
    CGRect rimRect = CGRectInset(self.bounds, 0.6, 0.6);
    _rimMask.frame = self.bounds;
    _rimMask.path = [UIBezierPath bezierPathWithRoundedRect:rimRect cornerRadius:MAX(radius - 0.6, 0)].CGPath;

    _highlight.frame = CGRectMake(0, 0, CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds) * 0.52);

    UIBezierPath *shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:radius];
    self.layer.shadowPath = shadowPath.CGPath;
}

@end

#pragma mark - Touch button

typedef NS_ENUM(NSInteger, ACTouchButtonStyle) {
    ACTouchButtonStyleRound = 0,
    ACTouchButtonStyleCapsule
};

@interface ACTouchButton : UIControl
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSLayoutConstraint *iconWidthConstraint;
@property (nonatomic, strong) NSLayoutConstraint *iconHeightConstraint;
@property (nonatomic, strong) ACGlassView *glass;
@property (nonatomic) int keyCode;
@property (nonatomic) NSInteger styleMode;
@property (nonatomic) BOOL keyIsDown;
@property (nonatomic) BOOL sendsKey;
@end

@implementation ACTouchButton

- (instancetype)initWithIdentifier:(NSString *)identifier title:(NSString *)title symbol:(NSString *)symbol
{
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _identifier = identifier;
        _title = title;
        _styleMode = ACTouchButtonStyleRound;
        _sendsKey = YES;

        _glass = [[ACGlassView alloc] initWithFrame:CGRectZero];
        _glass.glassRadius = 18;
        _glass.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_glass];

        _iconView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol]];
        _iconView.tintColor = UIColor.whiteColor;
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_iconView];

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.text = title;
        _titleLabel.textColor = ACWhite(0.92);
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightMedium];
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.7;
        _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_titleLabel];

        [NSLayoutConstraint activateConstraints:@[
            [_glass.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_glass.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_glass.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_glass.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_iconView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_iconView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor constant:-6],
            (_iconWidthConstraint = [_iconView.widthAnchor constraintEqualToConstant:26]),
            (_iconHeightConstraint = [_iconView.heightAnchor constraintEqualToConstant:26]),

            [_titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
            [_titleLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [_titleLabel.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-5],
        ]];

        self.accessibilityLabel = title;
        self.isAccessibilityElement = YES;

        [self addTarget:self action:@selector(handleTouchDown) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(handleTouchUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat side = MIN(CGRectGetWidth(self.bounds), CGRectGetHeight(self.bounds));
    _glass.glassRadius = (self.styleMode == ACTouchButtonStyleCapsule) ? CGRectGetHeight(self.bounds) * 0.5 : side * 0.5;
    CGFloat iconSide = MAX(18.0, side * 0.34);
    _iconWidthConstraint.constant = iconSide;
    _iconHeightConstraint.constant = iconSide;
    _titleLabel.font = [UIFont systemFontOfSize:MAX(9.0, side * 0.13) weight:UIFontWeightMedium];
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    [self setPressed:YES];
    return [super beginTrackingWithTouch:touch withEvent:event];
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    CGPoint p = [touch locationInView:self];
    BOOL inside = CGRectContainsPoint(CGRectInset(self.bounds, -12, -12), p);
    [self setPressed:inside];
    return [super continueTrackingWithTouch:touch withEvent:event];
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event
{
    [self setPressed:NO];
    [super endTrackingWithTouch:touch withEvent:event];
}

- (void)cancelTrackingWithEvent:(UIEvent *)event
{
    [self setPressed:NO];
    [super cancelTrackingWithEvent:event];
}

- (void)handleTouchDown { [self setPressed:YES]; }
- (void)handleTouchUp   { [self setPressed:NO]; }

- (void)setPressed:(BOOL)pressed
{
    if (pressed == _keyIsDown) return;
    _keyIsDown = pressed;
    if (_sendsKey) ac_ios_key(_keyCode, pressed ? 1 : 0);

    [UIView animateWithDuration:pressed ? 0.16 : 0.30
                          delay:0
         usingSpringWithDamping:pressed ? 0.55 : 0.42
          initialSpringVelocity:pressed ? 0.9 : 0.6
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{
        self.transform = pressed ? CGAffineTransformMakeScale(0.90, 0.90) : CGAffineTransformIdentity;
        self.alpha = pressed ? 1.0 : 0.94;
        self.glass.layer.shadowOpacity = pressed ? 0.5 : 0.28;
    } completion:nil];
}

- (void)releaseIfNeeded
{
    if (_keyIsDown) {
        _keyIsDown = NO;
        if (_sendsKey) ac_ios_key(_keyCode, 0);
    }
}

@end

#pragma mark - Joystick

@interface ACJoystickView : UIView
@property (nonatomic, strong) ACGlassView *base;
@property (nonatomic, strong) ACGlassView *knob;
@property (nonatomic) CGFloat baseRadius;
@end

@implementation ACJoystickView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        _base = [[ACGlassView alloc] initWithFrame:CGRectZero];
        _base.glassRadius = 0;
        [self addSubview:_base];
        _knob = [[ACGlassView alloc] initWithFrame:CGRectZero];
        _knob.glassRadius = 14;
        [self addSubview:_knob];
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    _base.frame = self.bounds;
    CGFloat knobSide = MIN(CGRectGetWidth(self.bounds) * 0.44, 58);
    _knob.frame = CGRectMake((CGRectGetWidth(self.bounds) - knobSide) * 0.5,
                             (CGRectGetHeight(self.bounds) - knobSide) * 0.5,
                             knobSide, knobSide);
    _knob.glassRadius = knobSide * 0.5;
}

- (void)moveKnobTo:(CGPoint)point radius:(CGFloat)radius
{
    CGFloat knobSide = CGRectGetWidth(_knob.bounds);
    CGFloat maxOffset = MAX(0, CGRectGetWidth(self.bounds) * 0.5 - knobSide * 0.5 - 4);
    CGPoint c = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    CGVector v = CGVectorMake(point.x - c.x, point.y - c.y);
    CGFloat len = hypot(v.dx, v.dy);
    if (len > maxOffset && len > 0) { v.dx *= maxOffset / len; v.dy *= maxOffset / len; }
    _knob.transform = CGAffineTransformMakeTranslation(v.dx, v.dy);
}

- (void)resetKnob
{
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.5 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.knob.transform = CGAffineTransformIdentity;
    } completion:nil];
}

@end

#pragma mark - Movement zone

@interface ACMoveZone : UIView
@property (nonatomic, strong) ACJoystickView *stick;
@property (nonatomic, copy) void (^onDirection)(int code);
@property (nonatomic) BOOL active;
@property (nonatomic) CGPoint anchor;
@property (nonatomic) CGPoint restCenter;
@property (nonatomic) CGFloat stickSize;
@property (nonatomic) int activeCode;
@property (nonatomic) NSInteger moveZoneSide; // 0 left, 1 right (handedness)
@end

@implementation ACMoveZone

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = NO;
        _stick = [[ACJoystickView alloc] initWithFrame:CGRectZero];
        [self addSubview:_stick];
        _activeCode = 0;
    }
    return self;
}

- (void)layoutSubviews
{
    [super layoutSubviews];
    CGFloat side = _stickSize > 0 ? _stickSize : 140;
    _stick.bounds = CGRectMake(0, 0, side, side);
    _stick.center = self.restCenter;
    _stick.base.glassRadius = side * 0.5;
    [_stick setNeedsLayout];
}

- (void)setRestPosition:(CGPoint)center
{
    _restCenter = center;
    _stick.center = center;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (_active) return;
    UITouch *t = touches.anyObject;
    _active = YES;
    _anchor = [t locationInView:self];
    // Dynamic joystick: the base jumps under the thumb, like modern mobile shooters.
    _stick.center = _anchor;
    _stick.hidden = NO;
    _stick.alpha = 0.0;
    [UIView animateWithDuration:0.18 animations:^{ self.stick.alpha = 1.0; }];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (!_active) return;
    UITouch *t = touches.anyObject;
    CGPoint p = [t locationInView:self];
    [_stick moveKnobTo:p radius:0];

    CGFloat dx = p.x - _anchor.x;
    CGFloat dy = p.y - _anchor.y;
    CGFloat dead = MAX(10.0, CGRectGetWidth(_stick.bounds) * 0.16);
    if (hypot(dx, dy) < dead) {
        [self sendCode:0];
        return;
    }
    // 8 sectors: 0=right, 45=up-right, 90=up ...
    CGFloat angle = atan2(-dy, dx) * 180.0 / M_PI;
    if (angle < 0) angle += 360.0;
    int sector = (int)floor((angle + 22.5) / 45.0) % 8;

    // Engine touch codes (see cube.h)
    static const int codes[8] = { 10027, 10020, 10021, 10022, 10023, 10024, 10025, 10026 };
    [self sendCode:codes[sector]];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouch];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    [self finishTouch];
}

- (void)finishTouch
{
    _active = NO;
    [self sendCode:0];
    [_stick resetKnob];
    [UIView animateWithDuration:0.22 delay:0.05 options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self.stick.alpha = 0.55;
        self.stick.center = self.restCenter;
    } completion:nil];
}

- (void)sendCode:(int)code
{
    if (code == _activeCode) return;
    if (_activeCode) ac_ios_key(_activeCode, 0);
    _activeCode = code;
    if (code) ac_ios_key(code, 1);
    if (self.onDirection) self.onDirection(code);
}

- (void)releaseAll
{
    [self sendCode:0];
    _active = NO;
}

@end

#pragma mark - Actions

static NSArray<NSDictionary *> *ACActions(void)
{
    static NSArray *actions = nil;
    if (actions) return actions;
    actions = @[
        @{@"id": @"attack",    @"title": @"开火",   @"cmd": @"attack",                    @"code": @(-1)},
        @{@"id": @"jump",      @"title": @"跳跃",   @"cmd": @"jump",                      @"code": @(32)},
        @{@"id": @"crouch",    @"title": @"蹲下",   @"cmd": @"crouch",                    @"code": @(SDLK_LSHIFT)},
        @{@"id": @"reload",    @"title": @"换弹",   @"cmd": @"reload",                    @"code": @(114)},
        @{@"id": @"next",      @"title": @"下一把", @"cmd": @"key_universaldelta_plus",   @"code": @(-4)},
        @{@"id": @"prev",      @"title": @"上一把", @"cmd": @"key_universaldelta_minus",  @"code": @(-5)},
        @{@"id": @"primary",   @"title": @"主武器", @"cmd": @"primary",                   @"code": @(49)},
        @{@"id": @"secondary", @"title": @"副武器", @"cmd": @"secondary",                 @"code": @(50)},
        @{@"id": @"grenade",   @"title": @"手雷",   @"cmd": @"grenades",                  @"code": @(51)},
        @{@"id": @"melee",     @"title": @"近战",   @"cmd": @"melee",                     @"code": @(52)},
        @{@"id": @"scope",     @"title": @"狙击镜", @"cmd": @"altaction",                 @"code": @(-2)},
        @{@"id": @"scores",    @"title": @"计分板", @"cmd": @"key_showscores",            @"code": @(9)},
        @{@"id": @"menu",      @"title": @"菜单",   @"cmd": @"key_escape",                @"code": @(27)}
    ];
    return actions;
}

static NSDictionary *ACActionForIdentifier(NSString *identifier)
{
    for (NSDictionary *a in ACActions()) if ([a[@"id"] isEqualToString:identifier]) return a;
    return ACActions().firstObject;
}

static NSString *ACKeyNameForSDLKey(int sym)
{
    switch (sym) {
        case -5: return @"MOUSE5";
        case -4: return @"MOUSE4";
        case -3: return @"MOUSE3";
        case -2: return @"MOUSE2";
        case -1: return @"MOUSE1";
        case SDLK_SPACE: return @"SPACE";
        case SDLK_RETURN: return @"RETURN";
        case SDLK_ESCAPE: return @"ESCAPE";
        case SDLK_TAB: return @"TAB";
        case SDLK_BACKSPACE: return @"BACKSPACE";
        case SDLK_DELETE: return @"DELETE";
        case SDLK_LSHIFT: return @"LSHIFT";
        case SDLK_RSHIFT: return @"RSHIFT";
        case SDLK_LCTRL: return @"LCTRL";
        case SDLK_RCTRL: return @"RCTRL";
        case SDLK_LALT: return @"LALT";
        case SDLK_RALT: return @"RALT";
        case SDLK_LGUI: return @"LGUI";
        case SDLK_RGUI: return @"RGUI";
        case SDLK_UP: return @"UP";
        case SDLK_DOWN: return @"DOWN";
        case SDLK_LEFT: return @"LEFT";
        case SDLK_RIGHT: return @"RIGHT";
        case SDLK_COMMA: return @"COMMA";
        case SDLK_PERIOD: return @"PERIOD";
        case SDLK_SEMICOLON: return @"SEMICOLON";
        case SDLK_QUOTE: return @"QUOTE";
        case SDLK_MINUS: return @"MINUS";
        case SDLK_EQUALS: return @"EQUALS";
        case SDLK_LEFTBRACKET: return @"LEFTBRACKET";
        case SDLK_RIGHTBRACKET: return @"RIGHTBRACKET";
        case SDLK_BACKSLASH: return @"BACKSLASH";
        case SDLK_SLASH: return @"SLASH";
        case SDLK_BACKQUOTE: return @"BACKQUOTE";
        default: break;
    }
    if (sym >= SDLK_a && sym <= SDLK_z) return [[NSString stringWithFormat:@"%c", (char)sym] uppercaseString];
    if (sym >= SDLK_0 && sym <= SDLK_9) return [NSString stringWithFormat:@"%c", (char)sym];
    if (sym >= SDLK_F1 && sym <= SDLK_F12) return [NSString stringWithFormat:@"F%d", sym - SDLK_F1 + 1];

    const char *raw = SDL_GetKeyName((SDL_Keycode)sym);
    if (raw && *raw) {
        NSString *s = [NSString stringWithUTF8String:raw];
        // SDL returns friendly names ("Left Shift"); AC wants the keymap token.
        NSDictionary *alias = @{
            @"Left Shift": @"LSHIFT", @"Right Shift": @"RSHIFT",
            @"Left Ctrl": @"LCTRL", @"Right Ctrl": @"RCTRL",
            @"Left Alt": @"LALT", @"Right Alt": @"RALT",
            @"Left GUI": @"LGUI", @"Right GUI": @"RGUI"
        };
        if (alias[s]) return alias[s];
        return [s stringByReplacingOccurrencesOfString:@" " withString:@""].uppercaseString;
    }
    return @"UNKNOWN";
}

#pragma mark - Overlay

@class ACTouchOverlay;
@interface ACSettingsViewController : UIViewController
- (instancetype)initWithOverlay:(ACTouchOverlay *)overlay;
@end

@interface ACTouchOverlay : UIView
@property (nonatomic, strong) ACMoveZone *moveZone;
@property (nonatomic, strong) NSMutableDictionary<NSString *, ACTouchButton *> *buttons;
@property (nonatomic, weak) ACTouchButton *settingsButton;
@property (nonatomic, weak) ACTouchButton *scoresButton;
@property (nonatomic, weak) ACTouchButton *menuButton;
@property (nonatomic) BOOL controlsVisible;
@property (nonatomic) BOOL leftHanded;
@property (nonatomic) CGFloat buttonScale;
@property (nonatomic) CGFloat controlAlpha;
@property (nonatomic, strong) NSTimer *stateTimer;
- (void)refreshAppearance;
- (void)pollEngineState;
- (void)releaseAllKeys;
- (void)layoutForCurrentBounds;
- (void)place:(NSString *)ident rect:(CGRect)rect;
@end

@implementation ACTouchOverlay

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.multipleTouchEnabled = YES;
        _buttons = [NSMutableDictionary dictionary];

        NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
        _leftHanded = [d boolForKey:kLeftHanded];
        _buttonScale = [d objectForKey:kButtonScale] ? [d doubleForKey:kButtonScale] : 1.0;
        _controlAlpha = [d objectForKey:kControlAlpha] ? [d doubleForKey:kControlAlpha] : 0.82;
        _controlsVisible = [d objectForKey:kShowControls] ? [d boolForKey:kShowControls] : YES;

        _moveZone = [[ACMoveZone alloc] initWithFrame:CGRectZero];
        [self addSubview:_moveZone];

        NSDictionary *codes = [d dictionaryForKey:kButtonCodes];

        NSArray *specs = @[
            @[@"fire",    @"开火",   @"scope"],
            @[@"jump",    @"跳跃",   @"arrow.up"],
            @[@"crouch",  @"蹲下",   @"arrow.down.to.line"],
            @[@"reload",  @"换弹",   @"arrow.triangle.2.circlepath"],
            @[@"prev",    @"上一把", @"chevron.left"],
            @[@"next",    @"下一把", @"chevron.right"],
            @[@"scope",   @"狙击镜", @"magnifyingglass"],
            @[@"primary", @"主武器", @"1.circle"],
            @[@"secondary", @"副武器", @"2.circle"],
            @[@"grenade", @"手雷",   @"3.circle"],
            @[@"melee",   @"近战",   @"4.circle"],
            @[@"scores",  @"计分",   @"list.bullet"],
            @[@"menu",    @"菜单",   @"line.3.horizontal"]
        ];

        for (NSArray *spec in specs) {
            NSString *ident = spec[0];
            ACTouchButton *b = [[ACTouchButton alloc] initWithIdentifier:ident title:spec[1] symbol:spec[2]];
            NSDictionary *action = ACActionForIdentifier(ident);
            NSNumber *override = codes[ident];
            b.keyCode = override ? override.intValue : [action[@"code"] intValue];
            b.styleMode = ACTouchButtonStyleRound;
            [_buttons setObject:b forKey:ident];
            [self addSubview:b];
        }

        ACTouchButton *settings = [[ACTouchButton alloc] initWithIdentifier:@"settings" title:@"设置" symbol:@"gearshape.fill"];
        settings.keyCode = -1000; // local button, never forwarded
        settings.sendsKey = NO;
        [settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:settings];
        _settingsButton = settings;

        _scoresButton = _buttons[@"scores"];
        _menuButton = _buttons[@"menu"];


        _stateTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(stateTimerFired:) userInfo:nil repeats:YES];
        [self layoutForCurrentBounds];
    }
    return self;
}

- (void)dealloc
{
    [_stateTimer invalidate];
}

// Empty areas must fall through to the SDL view so look-drag still works.
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    UIView *v = [super hitTest:point withEvent:event];
    return (v == self) ? nil : v;
}

- (void)didMoveToWindow
{
    [super didMoveToWindow];
    [self layoutForCurrentBounds];
}

- (void)safeAreaInsetsDidChange
{
    [super safeAreaInsetsDidChange];
    [self layoutForCurrentBounds];
}

- (void)stateTimerFired:(NSTimer *)timer
{
    [self pollEngineState];
}

- (void)pollEngineState
{
    BOOL menu = touchmenuvisible();
    BOOL showPlay = _controlsVisible && !menu && !ac_ios_input_blocked;

    if (!showPlay) {
        [_moveZone releaseAll];
        for (ACTouchButton *b in _buttons.allValues) [b releaseIfNeeded];
    }

    _moveZone.hidden = !showPlay;
    _moveZone.userInteractionEnabled = showPlay;
    for (ACTouchButton *b in _buttons.allValues) {
        b.hidden = !showPlay;
        b.userInteractionEnabled = showPlay;
    }
    // The gear must stay reachable even when the player hides the play controls,
    // otherwise the switch that hides them can never be undone.
    _settingsButton.hidden = ac_ios_input_blocked;
    _settingsButton.userInteractionEnabled = !ac_ios_input_blocked;

    [self refreshAppearance];
}

- (void)refreshAppearance
{
    for (ACTouchButton *b in _buttons.allValues) b.alpha = self.controlAlpha;
    _moveZone.alpha = self.controlAlpha;
    _settingsButton.alpha = 1.0;
}

- (void)openSettings
{
    [self releaseAllKeys];
    ac_ios_input_blocked = 1;
    _settingsButton.enabled = NO;
    _settingsButton.hidden = YES;
    _moveZone.hidden = YES;
    for (ACTouchButton *b in _buttons.allValues) b.hidden = YES;

    UIViewController *root = self.window.rootViewController;
    if (!root) {
        ac_ios_input_blocked = 0;
        _settingsButton.enabled = YES;
        _settingsButton.hidden = NO;
        [self pollEngineState];
        return;
    }

    ACSettingsViewController *vc = [[ACSettingsViewController alloc] initWithOverlay:self];
    vc.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 16.0, *)) {
        if ([vc.sheetPresentationController isKindOfClass:UISheetPresentationController.class]) {
            UISheetPresentationController *sheet = (UISheetPresentationController *)vc.sheetPresentationController;
            sheet.detents = @[[UISheetDetent mediumDetent], [UISheetDetent largeDetent]];
            sheet.prefersGrabberVisible = YES;
            sheet.preferredCornerRadius = 28;
        }
    }
    [root presentViewController:vc animated:YES completion:^{
        self.settingsButton.enabled = YES;
    }];
}

- (void)releaseAllKeys
{
    [_moveZone releaseAll];
    for (ACTouchButton *b in _buttons.allValues) [b releaseIfNeeded];
}

- (void)layoutForCurrentBounds
{
    UIEdgeInsets sa = self.safeAreaInsets;
    CGFloat W = CGRectGetWidth(self.bounds);
    CGFloat H = CGRectGetHeight(self.bounds);
    if (W <= 0 || H <= 0) return;
    CGFloat S = MAX(0.7, MIN(1.4, self.buttonScale));
    CGFloat top = MAX(sa.top, 6);
    CGFloat bottom = MAX(sa.bottom, 6);
    CGFloat left = MAX(sa.left, 8);
    CGFloat right = MAX(sa.right, 8);

    // Movement zone owns one half of the screen; the other half is look-drag.
    CGFloat zoneW = W * 0.5;
    _moveZone.frame = CGRectMake(_leftHanded ? W - zoneW : 0, 0, zoneW, H);
    _moveZone.stickSize = 148 * S;
    CGPoint rest = _leftHanded
        ? CGPointMake(zoneW - 20 - _moveZone.stickSize * 0.5, H - bottom - 16 - _moveZone.stickSize * 0.5)
        : CGPointMake(20 + _moveZone.stickSize * 0.5, H - bottom - 16 - _moveZone.stickSize * 0.5);
    [_moveZone setRestPosition:rest];

    CGFloat fire = 92 * S;
    CGFloat jump = 72 * S;
    CGFloat small = 56 * S;
    CGFloat tiny = 46 * S;
    CGFloat gap = 10 * S;

    CGRect fireRect = CGRectZero;
    CGFloat anchorX = _leftHanded ? left : W - right;
    CGFloat dir = _leftHanded ? -1.0 : 1.0;
    // fire bottom corner
    fireRect = CGRectMake(_leftHanded ? left : W - right - fire, H - bottom - fire, fire, fire);
    [self place:@"fire" rect:fireRect];

    // jump above fire, slightly inward
    CGRect jumpRect = CGRectMake(_leftHanded ? left + 8 : W - right - fire + (fire - jump) / 2,
                                 CGRectGetMinY(fireRect) - jump - 12 * S, jump, jump);
    [self place:@"jump" rect:jumpRect];

    // reload / crouch stack inward from fire
    CGFloat colX = _leftHanded ? left + fire + gap : W - right - fire - gap - small;
    CGRect reloadRect = CGRectMake(colX, CGRectGetMinY(fireRect) + (fire - small) * 0.5, small, small);
    [self place:@"reload" rect:reloadRect];
    CGRect crouchRect = CGRectMake(colX, CGRectGetMinY(reloadRect) - small - gap, small, small);
    [self place:@"crouch" rect:crouchRect];

    // scope + weapon cycling
    CGFloat col2X = _leftHanded ? left + fire + gap + small + gap : W - right - fire - gap - small - gap - tiny;
    CGRect scopeRect = CGRectMake(col2X, CGRectGetMinY(fireRect) + (fire - tiny) * 0.5, tiny, tiny);
    [self place:@"scope" rect:scopeRect];
    CGRect nextRect = CGRectMake(col2X, CGRectGetMinY(scopeRect) - tiny - gap * 0.8, tiny, tiny);
    [self place:@"next" rect:nextRect];
    CGRect prevRect = CGRectMake(col2X, CGRectGetMinY(nextRect) - tiny - gap * 0.8, tiny, tiny);
    [self place:@"prev" rect:prevRect];

    // weapon slots strip, centered bottom
    CGFloat slot = 44 * S;
    CGFloat slotGap = 8 * S;
    CGFloat stripW = slot * 4 + slotGap * 3;
    CGFloat stripX = W * 0.5 - stripW * 0.5;
    CGFloat stripY = H - bottom - slot - 8 * S;
    NSArray *slots = @[@"primary", @"secondary", @"grenade", @"melee"];
    for (NSUInteger i = 0; i < slots.count; i++) {
        [self place:slots[i] rect:CGRectMake(stripX + i * (slot + slotGap), stripY, slot, slot)];
    }

    // top chrome
    CGFloat topY = top + 2;
    [self place:@"settings" rect:CGRectMake(_leftHanded ? W - right - 44 : left, topY, 44, 44)];
    [self place:@"scores" rect:CGRectMake(W * 0.5 - 22, topY, 44, 44)];
    [self place:@"menu" rect:CGRectMake(_leftHanded ? left : W - right - 44, topY, 44, 44)];

    (void)anchorX; (void)dir;
    [self refreshAppearance];
}

- (void)place:(NSString *)ident rect:(CGRect)rect
{
    UIView *v = nil;
    if ([ident isEqualToString:@"settings"]) v = _settingsButton;
    else v = _buttons[ident];
    if (!v) return;
    v.frame = rect;
    v.transform = CGAffineTransformIdentity;
}

- (void)applyScaleAndAlpha
{
    [self layoutForCurrentBounds];
    self.alpha = self.controlAlpha;
}

@end

#pragma mark - Settings UI

static BOOL ACCaptureActive = NO;
static void (^ACCaptureHandler)(int sym) = nil;

static int ACKeyEventWatch(void *userdata, SDL_Event *event)
{
    if (!ACCaptureActive || !event) return 1;
    if (event->type == SDL_KEYDOWN) {
        int sym = (int)event->key.keysym.sym;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ACCaptureHandler) {
                void (^h)(int) = ACCaptureHandler;
                ACCaptureHandler = nil;
                ACCaptureActive = NO;
                h(sym);
            }
        });
    }
    return 1;
}

@interface ACSettingsViewController () <UIGestureRecognizerDelegate>
@property (nonatomic, weak) ACTouchOverlay *overlay;
@property (nonatomic, strong) UIScrollView *scroll;
@property (nonatomic, strong) UIStackView *stack;
@property (nonatomic, strong) UILabel *captureLabel;
@end

@implementation ACSettingsViewController

- (instancetype)initWithOverlay:(ACTouchOverlay *)overlay
{
    self = [super initWithNibName:nil bundle:nil];
    if (self) { _overlay = overlay; }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.55];

    // Ambient ground so the glass has something to refract (Liquid Glass needs it).
    CAGradientLayer *ambient = [CAGradientLayer layer];
    ambient.frame = self.view.bounds;
    ambient.colors = @[(__bridge id)[UIColor colorWithRed:0.10 green:0.16 blue:0.28 alpha:1].CGColor,
                       (__bridge id)[UIColor colorWithRed:0.16 green:0.10 blue:0.22 alpha:1].CGColor,
                       (__bridge id)[UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:1].CGColor];
    ambient.locations = @[@0.0, @0.5, @1.0];
    ambient.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view.layer addSublayer:ambient];

    _scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];

    _stack = [[UIStackView alloc] initWithFrame:CGRectZero];
    _stack.axis = UILayoutConstraintAxisVertical;
    _stack.spacing = 16;
    _stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:_stack];

    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [_stack.topAnchor constraintEqualToAnchor:_scroll.topAnchor constant:18],
        [_stack.bottomAnchor constraintEqualToAnchor:_scroll.bottomAnchor constant:-28],
        [_stack.leadingAnchor constraintEqualToAnchor:_scroll.leadingAnchor constant:18],
        [_stack.trailingAnchor constraintEqualToAnchor:_scroll.trailingAnchor constant:-18],
        [_stack.widthAnchor constraintEqualToAnchor:_scroll.widthAnchor constant:-36]
    ]];

    [self buildHeader];
    [self buildControlsSection];
    [self buildSensitivitySection];
    [self buildKeyboardSection];
    [self buildTouchBindingsSection];
    [self buildResetSection];

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SDL_AddEventWatch(ACKeyEventWatch, NULL);
    });
    ac_ios_exec("touchattackcontrol 2");
    ac_ios_exec("touchjumpcontrol 1");
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    self.scroll.contentInset = UIEdgeInsetsMake(0, 0, 24, 0);
}

#pragma mark building blocks

- (UILabel *)sectionTitle:(NSString *)text
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.textColor = ACWhite(0.62);
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.numberOfLines = 1;
    return l;
}

- (ACGlassView *)card
{
    ACGlassView *c = [[ACGlassView alloc] initWithFrame:CGRectZero];
    c.glassRadius = 22;
    c.userInteractionEnabled = YES;
    c.translatesAutoresizingMaskIntoConstraints = NO;
    return c;
}

- (UIStackView *)rowsInCard:(ACGlassView *)card
{
    UIStackView *rows = [[UIStackView alloc] initWithFrame:CGRectZero];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 0;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    card.userInteractionEnabled = YES;
    [card addSubview:rows];
    [NSLayoutConstraint activateConstraints:@[
        [rows.topAnchor constraintEqualToAnchor:card.topAnchor constant:6],
        [rows.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-6],
        [rows.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:14],
        [rows.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-14]
    ]];
    return rows;
}

- (UIView *)rowWithTitle:(NSString *)title valueView:(UIView *)valueView
{
    UIControl *row = [[UIControl alloc] initWithFrame:CGRectZero];
    row.translatesAutoresizingMaskIntoConstraints = NO;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = title;
    l.textColor = ACWhite(0.94);
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:l];

    valueView.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:valueView];

    [NSLayoutConstraint activateConstraints:@[
        [row.heightAnchor constraintGreaterThanOrEqualToConstant:48],
        [l.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [l.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [valueView.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [valueView.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
        [l.trailingAnchor constraintLessThanOrEqualToAnchor:valueView.leadingAnchor constant:-10]
    ]];

    UIView *hair = [[UIView alloc] initWithFrame:CGRectZero];
    hair.backgroundColor = ACWhite(0.12);
    hair.translatesAutoresizingMaskIntoConstraints = NO;
    [row addSubview:hair];
    [NSLayoutConstraint activateConstraints:@[
        [hair.heightAnchor constraintEqualToConstant:0.5],
        [hair.leadingAnchor constraintEqualToAnchor:row.leadingAnchor],
        [hair.trailingAnchor constraintEqualToAnchor:row.trailingAnchor],
        [hair.bottomAnchor constraintEqualToAnchor:row.bottomAnchor]
    ]];
    return row;
}

- (UISwitch *)switchWithKey:(NSString *)key defaultValue:(BOOL)def onChange:(void (^)(BOOL))onChange
{
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    UISwitch *s = [[UISwitch alloc] initWithFrame:CGRectZero];
    s.onTintColor = [UIColor colorWithRed:0.20 green:0.52 blue:1.0 alpha:1.0];
    s.on = [d objectForKey:key] ? [d boolForKey:key] : def;
    [s addAction:[UIAction actionWithHandler:^(UIAction *a) {
        UISwitch *sw = (UISwitch *)a.sender;
        [d setBool:sw.on forKey:key];
        if (onChange) onChange(sw.on);
    }] forControlEvents:UIControlEventValueChanged];
    return s;
}

#pragma mark sections

- (void)buildHeader
{
    UIView *header = [[UIView alloc] initWithFrame:CGRectZero];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectZero];
    title.text = @"设置";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont systemFontOfSize:30 weight:UIFontWeightBold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:title];

    UIButton *done = [UIButton buttonWithType:UIButtonTypeSystem];
    [done setTitle:@"完成" forState:UIControlStateNormal];
    done.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    done.tintColor = UIColor.whiteColor;
    done.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
    done.layer.cornerRadius = 18;
    done.layer.cornerCurve = kCACornerCurveContinuous;
    done.translatesAutoresizingMaskIntoConstraints = NO;
    [done addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [self dismissSheet];
    }] forControlEvents:UIControlEventTouchUpInside];
    [header addSubview:done];

    [NSLayoutConstraint activateConstraints:@[
        [header.heightAnchor constraintEqualToConstant:52],
        [title.leadingAnchor constraintEqualToAnchor:header.leadingAnchor],
        [title.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [done.trailingAnchor constraintEqualToAnchor:header.trailingAnchor],
        [done.centerYAnchor constraintEqualToAnchor:header.centerYAnchor],
        [done.widthAnchor constraintEqualToConstant:76],
        [done.heightAnchor constraintEqualToConstant:36]
    ]];
    [self.stack addArrangedSubview:header];
}

- (void)buildControlsSection
{
    [self.stack addArrangedSubview:[self sectionTitle:@"触控"]];

    ACGlassView *card = [self card];
    UIStackView *rows = [self rowsInCard:card];

    UIView *showRow = [self rowWithTitle:@"显示触屏按键"
                              valueView:[self switchWithKey:kShowControls defaultValue:YES onChange:^(BOOL on) {
        self.overlay.controlsVisible = on;
        [self.overlay layoutForCurrentBounds];
    }]];
    [rows addArrangedSubview:showRow];

    UIView *leftyRow = [self rowWithTitle:@"左手模式"
                               valueView:[self switchWithKey:kLeftHanded defaultValue:NO onChange:^(BOOL on) {
        self.overlay.leftHanded = on;
        ac_ios_exec(on ? "ioslefthanded 1" : "ioslefthanded 0");
        [self.overlay layoutForCurrentBounds];
    }]];
    [rows addArrangedSubview:leftyRow];

    // size slider
    UISlider *size = [UISlider new];
    size.minimumValue = 0.75; size.maximumValue = 1.35;
    size.value = self.overlay.buttonScale;
    [size addAction:[UIAction actionWithHandler:^(UIAction *a) {
        self.overlay.buttonScale = ((UISlider *)a.sender).value;
        [NSUserDefaults.standardUserDefaults setDouble:self.overlay.buttonScale forKey:kButtonScale];
        [self.overlay layoutForCurrentBounds];
    }] forControlEvents:UIControlEventValueChanged];
    size.translatesAutoresizingMaskIntoConstraints = NO;
    [size.widthAnchor constraintEqualToConstant:150].active = YES;
    [rows addArrangedSubview:[self rowWithTitle:@"按钮大小" valueView:size]];

    UISlider *alpha = [UISlider new];
    alpha.minimumValue = 0.35; alpha.maximumValue = 1.0;
    alpha.value = self.overlay.controlAlpha;
    [alpha addAction:[UIAction actionWithHandler:^(UIAction *a) {
        self.overlay.controlAlpha = ((UISlider *)a.sender).value;
        [NSUserDefaults.standardUserDefaults setDouble:self.overlay.controlAlpha forKey:kControlAlpha];
        if (self.overlay.controlsVisible) self.overlay.alpha = self.overlay.controlAlpha;
    }] forControlEvents:UIControlEventValueChanged];
    alpha.translatesAutoresizingMaskIntoConstraints = NO;
    [alpha.widthAnchor constraintEqualToConstant:150].active = YES;
    [rows addArrangedSubview:[self rowWithTitle:@"不透明度" valueView:alpha]];

    [self.stack addArrangedSubview:card];
}

- (void)buildSensitivitySection
{
    [self.stack addArrangedSubview:[self sectionTitle:@"视角"]];

    ACGlassView *card = [self card];
    UIStackView *rows = [self rowsInCard:card];

    UISlider *sens = [UISlider new];
    sens.minimumValue = 0.5; sens.maximumValue = 10.0;
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    CGFloat saved = [d objectForKey:kSensitivity] ? [d doubleForKey:kSensitivity] : 3.0;
    sens.value = saved;
    [sens addAction:[UIAction actionWithHandler:^(UIAction *a) {
        float v = ((UISlider *)a.sender).value;
        [NSUserDefaults.standardUserDefaults setDouble:v forKey:kSensitivity];
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "sensitivity %.2f", v);
        ac_ios_exec(cmd);
    }] forControlEvents:UIControlEventValueChanged];
    sens.translatesAutoresizingMaskIntoConstraints = NO;
    [sens.widthAnchor constraintEqualToConstant:150].active = YES;
    [rows addArrangedSubview:[self rowWithTitle:@"灵敏度" valueView:sens]];

    [self.stack addArrangedSubview:card];

    char cmd[64];
    snprintf(cmd, sizeof(cmd), "sensitivity %.2f", (double)saved);
    ac_ios_exec(cmd);
}

- (void)buildKeyboardSection
{
    [self.stack addArrangedSubview:[self sectionTitle:@"外接键盘键位"]];

    UILabel *hint = [[UILabel alloc] initWithFrame:CGRectZero];
    hint.text = @"点一行，按一下键盘上的键即可重绑。蓝牙键盘由 iOS 直接转发。";
    hint.textColor = ACWhite(0.55);
    hint.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    hint.numberOfLines = 0;
    [self.stack addArrangedSubview:hint];

    ACGlassView *card = [self card];
    UIStackView *rows = [self rowsInCard:card];

    NSDictionary *bindings = [NSUserDefaults.standardUserDefaults dictionaryForKey:kKeyBindings] ?: @{};

    for (NSDictionary *action in ACActions()) {
        NSString *ident = action[@"id"];
        NSString *title = action[@"title"];
        NSString *keyName = bindings[ident] ?: ACKeyNameForSDLKey([action[@"code"] intValue]);

        UIControl *row = (UIControl *)[self rowWithTitle:title valueView:[self valueLabel:keyName]];
        row.tag = [ACActions() indexOfObject:action];
        [row addAction:[UIAction actionWithHandler:^(UIAction *a) {
            UIControl *r = (UIControl *)a.sender;
            NSDictionary *act = ACActions()[r.tag];
            [self captureKeyForAction:act row:(UIControl *)r];
        }] forControlEvents:UIControlEventTouchUpInside];
        row.userInteractionEnabled = YES;
        [rows addArrangedSubview:row];
    }

    [self.stack addArrangedSubview:card];
}

- (UILabel *)valueLabel:(NSString *)text
{
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.textColor = ACWhite(0.80);
    l.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
    l.textAlignment = NSTextAlignmentRight;
    return l;
}

- (void)captureKeyForAction:(NSDictionary *)action row:(UIControl *)row
{
    UILabel *value = nil;
    for (UIView *v in row.subviews) if ([v isKindOfClass:UILabel.class]) value = (UILabel *)v;

    ACCaptureActive = YES;
    ACCaptureHandler = ^(int sym) {
        NSString *keyName = ACKeyNameForSDLKey(sym);
        NSMutableDictionary *bindings = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kKeyBindings] mutableCopy] ?: [NSMutableDictionary dictionary];
        bindings[action[@"id"]] = keyName;
        [NSUserDefaults.standardUserDefaults setObject:bindings forKey:kKeyBindings];

        char cmd[160];
        snprintf(cmd, sizeof(cmd), "bind %s %s", keyName.UTF8String, [action[@"cmd"] UTF8String]);
        ac_ios_exec(cmd);

        value.text = keyName;
        [self flashCaptured:keyName];
    };

    [self showCapturePrompt:@"请按下要绑定的键…"];
}

- (void)showCapturePrompt:(NSString *)text
{
    self.captureLabel.text = text;
    self.captureLabel.hidden = NO;
    [UIView animateWithDuration:0.2 animations:^{ self.captureLabel.alpha = 1.0; }];
}

- (void)flashCaptured:(NSString *)name
{
    self.captureLabel.text = [NSString stringWithFormat:@"已绑定 %@", name];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.2 animations:^{ self.captureLabel.alpha = 0.0; } completion:^(BOOL f) {
            self.captureLabel.hidden = YES;
            self.captureLabel.alpha = 1.0;
        }];
    });
}

- (void)buildTouchBindingsSection
{
    [self.stack addArrangedSubview:[self sectionTitle:@"触屏按键功能"]];

    ACGlassView *card = [self card];
    UIStackView *rows = [self rowsInCard:card];

    NSDictionary *codes = [NSUserDefaults.standardUserDefaults dictionaryForKey:kButtonCodes] ?: @{};

    NSArray *ordered = @[@"fire", @"jump", @"crouch", @"reload", @"next", @"prev", @"scope", @"primary", @"secondary", @"grenade", @"melee"];
    for (NSString *ident in ordered) {
        NSDictionary *action = ACActionForIdentifier(ident);
        int code = codes[ident] ? [codes[ident] intValue] : [action[@"code"] intValue];

        // find the action that currently owns this code
        NSString *currentTitle = action[@"title"];
        for (NSDictionary *a in ACActions()) if ([a[@"code"] intValue] == code) { currentTitle = a[@"title"]; break; }

        UIControl *row = (UIControl *)[self rowWithTitle:[NSString stringWithFormat:@"%@键", action[@"title"]]
                                               valueView:[self valueLabel:[currentTitle stringByAppendingString:@"  ›"]]];
        row.tag = [ACActions() indexOfObject:action];
        [row addAction:[UIAction actionWithHandler:^(UIAction *a) {
            [self pickFunctionForIdentifier:ident row:a.sender];
        }] forControlEvents:UIControlEventTouchUpInside];
        row.userInteractionEnabled = YES;
        [rows addArrangedSubview:row];
    }

    [self.stack addArrangedSubview:card];

    self.captureLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.captureLabel.text = @"请按下要绑定的键…";
    self.captureLabel.textColor = UIColor.whiteColor;
    self.captureLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.captureLabel.textAlignment = NSTextAlignmentCenter;
    self.captureLabel.backgroundColor = [UIColor colorWithWhite:0.10 alpha:0.85];
    self.captureLabel.layer.cornerRadius = 14;
    self.captureLabel.layer.cornerCurve = kCACornerCurveContinuous;
    self.captureLabel.clipsToBounds = YES;
    self.captureLabel.hidden = YES;
    self.captureLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.captureLabel];
    [NSLayoutConstraint activateConstraints:@[
        [self.captureLabel.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [self.captureLabel.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:14],
        [self.captureLabel.widthAnchor constraintEqualToConstant:260],
        [self.captureLabel.heightAnchor constraintEqualToConstant:46]
    ]];
}

- (void)pickFunctionForIdentifier:(NSString *)ident row:(UIControl *)row
{
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择功能" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *a in ACActions()) {
        [sheet addAction:[UIAlertAction actionWithTitle:a[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            NSMutableDictionary *codes = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kButtonCodes] mutableCopy] ?: [NSMutableDictionary dictionary];
            codes[ident] = a[@"code"];
            [NSUserDefaults.standardUserDefaults setObject:codes forKey:kButtonCodes];

            ACTouchButton *b = self.overlay.buttons[ident];
            [b releaseIfNeeded];
            b.keyCode = [a[@"code"] intValue];
            b.titleLabel.text = a[@"title"];

            UILabel *value = nil;
            for (UIView *v in row.subviews) if ([v isKindOfClass:UILabel.class]) value = (UILabel *)v;
            value.text = [a[@"title"] stringByAppendingString:@"  ›"];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = row;
    sheet.popoverPresentationController.sourceRect = row.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)buildResetSection
{
    UIControl *reset = [[UIControl alloc] initWithFrame:CGRectZero];
    reset.backgroundColor = [UIColor colorWithRed:0.58 green:0.10 blue:0.12 alpha:0.55];
    reset.layer.cornerRadius = 16;
    reset.layer.cornerCurve = kCACornerCurveContinuous;
    [reset.heightAnchor constraintEqualToConstant:52].active = YES;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = @"恢复默认键位";
    l.textColor = [UIColor colorWithRed:1.0 green:0.55 blue:0.55 alpha:1.0];
    l.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [reset addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:reset.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:reset.centerYAnchor]
    ]];

    [reset addAction:[UIAction actionWithHandler:^(UIAction *a) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kKeyBindings];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:kButtonCodes];
        ac_ios_exec("resetbinds");
        for (ACTouchButton *b in self.overlay.buttons.allValues) {
            [b releaseIfNeeded];
            NSDictionary *act = ACActionForIdentifier(b.identifier);
            b.keyCode = [act[@"code"] intValue];
            b.titleLabel.text = act[@"title"];
        }
        [self flashCaptured:@"已恢复默认"];
    }] forControlEvents:UIControlEventTouchUpInside];

    [self.stack addArrangedSubview:reset];
}

- (void)restoreGameInput
{
    ACCaptureActive = NO;
    ACCaptureHandler = nil;
    ac_ios_input_blocked = 0;
    [self.overlay releaseAllKeys];
    [self.overlay layoutForCurrentBounds];
    [self.overlay refreshAppearance];
    [self.overlay pollEngineState];
}

// Also fires when the sheet is swiped away, which bypasses dismissSheet.
- (void)viewDidDisappear:(BOOL)animated
{
    [super viewDidDisappear:animated];
    [self restoreGameInput];
}

- (void)dismissSheet
{
    [self restoreGameInput];
    [self dismissViewControllerAnimated:YES completion:nil];
}

@end

#pragma mark - Attach

static ACTouchOverlay *GOverlay = nil;

static void ACInstallOverlay(UIWindow *window)
{
    if (!window) return;
    if (GOverlay && GOverlay.window == window) return;
    if (GOverlay) { [GOverlay removeFromSuperview]; GOverlay = nil; }
    ACTouchOverlay *overlay = [[ACTouchOverlay alloc] initWithFrame:window.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [window addSubview:overlay];
    GOverlay = overlay;

    overlay.leftHanded = [NSUserDefaults.standardUserDefaults boolForKey:kLeftHanded];
    overlay.buttonScale = [NSUserDefaults.standardUserDefaults objectForKey:kButtonScale] ? [NSUserDefaults.standardUserDefaults doubleForKey:kButtonScale] : 1.0;
    overlay.controlAlpha = [NSUserDefaults.standardUserDefaults objectForKey:kControlAlpha] ? [NSUserDefaults.standardUserDefaults doubleForKey:kControlAlpha] : 0.82;
    overlay.controlsVisible = [NSUserDefaults.standardUserDefaults objectForKey:kShowControls] ? [NSUserDefaults.standardUserDefaults boolForKey:kShowControls] : YES;
    [overlay layoutForCurrentBounds];
    ac_ios_exec(overlay.leftHanded ? "ioslefthanded 1" : "ioslefthanded 0");

    // Apply saved bindings after the engine console is up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSDictionary *bindings = [NSUserDefaults.standardUserDefaults dictionaryForKey:kKeyBindings];
        for (NSString *ident in bindings) {
            NSDictionary *action = ACActionForIdentifier(ident);
            if (!action) continue;
            char cmd[160];
            snprintf(cmd, sizeof(cmd), "bind %s %s", [bindings[ident] UTF8String], [action[@"cmd"] UTF8String]);
            ac_ios_exec(cmd);
        }
        CGFloat sens = [NSUserDefaults.standardUserDefaults objectForKey:kSensitivity] ? [NSUserDefaults.standardUserDefaults doubleForKey:kSensitivity] : 3.0;
        char cmd[64];
        snprintf(cmd, sizeof(cmd), "sensitivity %.2f", sens);
        ac_ios_exec(cmd);
    });
}

// Called from the engine once an SDL window exists.
extern "C" void ac_ios_attach_overlay(void *sdlwindow)
{
    SDL_Window *win = (SDL_Window *)sdlwindow;
    if (!win) return;

    SDL_SysWMinfo info;
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(win, &info)) return;
#if defined(SDL_VIDEO_DRIVER_UIKIT)
    UIWindow *uiwin = info.info.uikit.window;
    if (!uiwin) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        ACInstallOverlay(uiwin);
    });
#else
    (void)info;
#endif
}
