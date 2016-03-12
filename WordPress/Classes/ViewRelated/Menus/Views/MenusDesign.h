#ifndef MenusDesign_h
#define MenusDesign_h

typedef NS_ENUM(NSUInteger) {
    MenuIconTypeNone,
    MenuIconTypeDefault,
    MenuIconTypeEdit,
    MenuIconTypeAdd,
}MenuIconType;

static CGFloat const MenusDesignDefaultCornerRadius = 4.0;
static CGFloat const MenusDesignDefaultContentSpacing = 18.0;
static CGFloat const MenusDesignItemIconSize = 10.0;

static inline UIEdgeInsets MenusDesignDefaultInsets() {
    return UIEdgeInsetsMake(10.0, 10.0, 10.0, 10.0);
}

static NSString * MenusDesignItemIconImageNameForType(MenuIconType type)
{
    NSString *name;
    switch (type) {
        case MenuIconTypeNone:
            name = nil;
            break;
        case MenuIconTypeDefault:
            name = @"icon-menus-document";
            break;
        case MenuIconTypeEdit:
            name = @"icon-menus-edit";
            break;
        case MenuIconTypeAdd:
            name = @"icon-menus-plus";
            break;
    }
    
    return name;
}

#endif /* MenusDesign_h */