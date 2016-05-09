#import "MenusViewController.h"
#import "Blog.h"
#import "MenusService.h"
#import "Menu.h"
#import "MenuLocation.h"
#import "MenuItem.h"
#import "WPStyleGuide.h"
#import "WPFontManager.h"
#import "MenusHeaderView.h"
#import "MenuDetailsView.h"
#import "MenuItemsViewController.h"
#import "MenuItemEditingViewController.h"
#import "WPNoResultsView.h"
#import "Menu+ViewDesign.h"
#import "ContextManager.h"

typedef NS_ENUM(NSInteger) {
    MenusSectionSelection = 0,
    MenusSectionMenuItems
    
}MenusSection;

static NSString * const MenusSectionMenuItemsKey = @"menu_items";

@implementation NSDictionary (Menus)

- (NSMutableArray *)menuItems
{
    return self[MenusSectionMenuItemsKey];
}

@end

@interface MenusViewController () <UIScrollViewDelegate, MenusHeaderViewDelegate, MenuDetailsViewDelegate, MenuItemsViewControllerDelegate>

@property (weak, nonatomic) IBOutlet UIScrollView *scrollView;
@property (weak, nonatomic) IBOutlet UIStackView *stackView;
@property (weak, nonatomic) IBOutlet MenusHeaderView *headerView;
@property (weak, nonatomic) IBOutlet MenuDetailsView *detailsView;
@property (weak, nonatomic) MenuItemsViewController *itemsView;

@property (nonatomic, strong, readonly) WPNoResultsView *loadingView;
@property (nonatomic, strong, readonly) UILabel *itemsLoadingLabel;
@property (nonatomic, strong, readonly) UIBarButtonItem *saveButtonItem;

@property (nonatomic, strong, readonly) Blog *blog;
@property (nonatomic, strong, readonly) MenusService *menusService;
@property (nonatomic, strong) MenuLocation *selectedMenuLocation;
@property (nonatomic, strong) Menu *updatedMenuForSaving;

@property (nonatomic, assign) BOOL observesKeyboardChanges;
@property (nonatomic, assign) BOOL animatesAppearanceAfterSync;
@property (nonatomic, assign) BOOL hasMadeSignificantMenuChanges;
@property (nonatomic, assign) BOOL needsSave;
@property (nonatomic, assign) BOOL isSaving;

@end

@implementation MenusViewController

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (id)initWithBlog:(Blog *)blog
{
    NSParameterAssert([blog isKindOfClass:[Blog class]]);
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Menus" bundle:nil];
    self = [storyboard instantiateInitialViewController];
    if (self) {
        
        // using a new child context to keep local changes disacardable
        // using main queue as we still want processing done on the main thread
        NSManagedObjectContext *context = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
        context.parentContext = blog.managedObjectContext;
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy;
        
        // set local blog from local context
        _blog = [context objectWithID:blog.objectID];
        
        // set up the undomanager
        context.undoManager = [[NSUndoManager alloc] init];

        MenusService *service = [[MenusService alloc] initWithManagedObjectContext:context];
        _menusService = service;
    }
    
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    
    self.automaticallyAdjustsScrollViewInsets = NO;
    self.navigationItem.title = NSLocalizedString(@"Menus", @"Title for screen that allows configuration of your site's menus");
    self.view.backgroundColor = [WPStyleGuide greyLighten30];

    self.scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.scrollView.backgroundColor = self.view.backgroundColor;
    self.scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    self.scrollView.alpha = 0.0;
    
    // add a bit of padding to the scrollable content
    self.stackView.layoutMargins = UIEdgeInsetsMake(0, 0, 10, 0);
    self.stackView.layoutMarginsRelativeArrangement = YES;
    
    self.headerView.delegate = self;
    self.detailsView.delegate = self;
    self.itemsView.delegate = self;
    
    [self setupSaveButtonItem];
    [self setupLoadingView];
    [self setupItemsLoadingLabel];
    
    [self syncWithBlogMenus];
}

- (void)setupSaveButtonItem
{
    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Save", @"Menus save button title") style:UIBarButtonSystemItemSave target:self action:@selector(saveBarButtonItemPressed:)];
    self.navigationItem.rightBarButtonItem = button;
    button.enabled = NO;
    _saveButtonItem = button;
}

- (void)setupLoadingView
{
    WPNoResultsView *loadingView = [[WPNoResultsView alloc] init];
    loadingView.titleText = NSLocalizedString(@"Loading Menus...", @"Menus label text displayed while menus are loading");;
    _loadingView = loadingView;
}

- (void)setupItemsLoadingLabel
{
    UILabel *label = [[UILabel alloc] init];
    label.font = [WPFontManager systemLightFontOfSize:14];
    label.textColor = [WPStyleGuide darkBlue];
    label.numberOfLines = 0;
    [self.stackView addArrangedSubview:label];
    [label.leadingAnchor constraintEqualToAnchor:self.stackView.leadingAnchor constant:MenusDesignDefaultContentSpacing].active = YES;
    [label.trailingAnchor constraintEqualToAnchor:self.stackView.trailingAnchor constant:-MenusDesignDefaultContentSpacing].active = YES;
    label.hidden = YES;
    _itemsLoadingLabel = label;
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender
{
    [super prepareForSegue:segue sender:sender];
    
    if ([[segue destinationViewController] isKindOfClass:[MenuItemsViewController class]]) {
        self.itemsView = segue.destinationViewController;
    }
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    
    [self updateScrollViewContentSize];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    
    self.animatesAppearanceAfterSync = YES;
    
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHideNotification:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShowNotification:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillChangeFrameNotification:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];

    self.animatesAppearanceAfterSync = NO;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Views setup

- (void)updateScrollViewContentSize
{
    self.scrollView.contentSize = CGSizeMake(self.stackView.frame.size.width, self.stackView.frame.size.height);
}

#pragma mark - local updates

- (void)syncWithBlogMenus
{
    [self.loadingView showInView:self.view];
    [self.loadingView centerInSuperview];

    [self.menusService syncMenusForBlog:self.blog
                                success:^{
                                    [self didSyncBlog];
                                }
                                failure:^(NSError *error) {
                                    DDLogDebug(@"MenusViewController could not sync menus for blog");
                                    self.loadingView.titleText = NSLocalizedString(@"An error occurred loading menus, please check your internet connection.", @"Menus text shown when an error occurred loading menus from the server.");
                                }];
}

- (void)didSyncBlog
{
    if (!self.blog.menuLocations.count) {
        self.loadingView.titleText = NSLocalizedString(@"No menus available", @"Menus text shown when no menus were available for loading the Menus editor.");
        return;
    }
    
    [self.loadingView removeFromSuperview];

    MenuLocation *selectedLocation = [self.blog.menuLocations firstObject];
    Menu *selectedMenu = selectedLocation.menu;
    self.selectedMenuLocation = selectedLocation;
    
    self.headerView.blog = self.blog;
    [self.headerView setSelectedLocation:selectedLocation];
    [self.headerView setSelectedMenu:selectedMenu];
    
    [self setViewsWithMenu:selectedMenu];
    
    if (!self.animatesAppearanceAfterSync) {
        self.scrollView.alpha = 1.0;
    } else {
        [UIView animateWithDuration:0.20 animations:^{
            self.scrollView.alpha = 1.0;
        } completion:^(BOOL finished) {
        }];
    }
}

- (void)reloadMenusViews
{
    self.headerView.blog = nil;
    self.headerView.blog = self.blog;
    [self.headerView setSelectedMenu:self.selectedMenuLocation.menu];
    [self setViewsWithMenu:nil];
    [self setViewsWithMenu:self.selectedMenuLocation.menu];
}

- (void)loadDefaultMenuItemsIfNeeded
{
    Menu *menu = self.selectedMenuLocation.menu;
    if (menu.items.count == 0) {
        
        self.itemsLoadingLabel.text = NSLocalizedString(@"Loading menu...", @"Menus label text displayed when a menu is loading.");
        self.itemsLoadingLabel.hidden = NO;
        
        __weak __typeof__(self) weakSelf = self;
        void(^successBlock)(NSArray<MenuItem *> *) = ^(NSArray<MenuItem *> *defaultItems) {
            weakSelf.itemsLoadingLabel.hidden = YES;
            
            BOOL menuEqualToSelectedMenu = weakSelf.selectedMenuLocation.menu == menu;
            if (defaultItems.count) {
                NSOrderedSet *items = [NSOrderedSet orderedSetWithArray:defaultItems];
                menu.items = items;
                if (menuEqualToSelectedMenu) {
                    weakSelf.itemsView.menu = nil;
                    weakSelf.itemsView.menu = menu;
                }
            } else {
                if (menuEqualToSelectedMenu) {
                    [weakSelf insertBlankMenuItemIfNeeded];
                }
            }
        };
        void(^failureBlock)(NSError *) = ^(NSError *error) {
            weakSelf.itemsLoadingLabel.text = NSLocalizedString(@"An error occurred loading the menu, pelase check your internet connection.", @"Menus error message seen when an error occurred loading a specific menu.");
        };
        [self.menusService generateDefaultMenuItemsForBlog:self.blog
                                                   success:successBlock
                                                   failure:failureBlock];
    }
}

- (void)insertBlankMenuItemIfNeeded
{
    Menu *menu = self.selectedMenuLocation.menu;
    if (!menu.items.count) {
        // Add a new empty item.
        MenuItem *item = [NSEntityDescription insertNewObjectForEntityForName:[MenuItem entityName] inManagedObjectContext:menu.managedObjectContext];
        item.name = [MenuItem defaultItemNameLocalized];
        item.type = MenuItemTypePage;
        item.menu = menu;
        
        [[ContextManager sharedInstance] saveContext:menu.managedObjectContext];
        
        self.itemsView.menu = nil;
        self.itemsView.menu = menu;
    }
}

- (void)setViewsWithMenu:(Menu *)menu
{
    self.detailsView.menu = menu;
    self.itemsView.menu = menu;

    self.itemsLoadingLabel.hidden = YES;
    if ([menu.menuID integerValue] == MenuDefaultID) {
        if ([self defaultMenuEnabledForSelectedLocation]) {
            // Set up as the default menu of page items.
            [self loadDefaultMenuItemsIfNeeded];
        } else {
            // Set up as "No Menu" selected.
            menu.items = nil;
            self.itemsView.menu = nil;
            self.detailsView.menu = nil;
        }
    } else {
        [self insertBlankMenuItemIfNeeded];
    }
}

- (void)setNeedsSave:(BOOL)needsSave forMenu:(Menu *)menu significantChanges:(BOOL)significant
{
    // Update the saving/changes states.
    self.needsSave = needsSave;
    self.hasMadeSignificantMenuChanges = significant;
    self.updatedMenuForSaving = menu;
}

- (void)setNeedsSave:(BOOL)needsSave
{
    if (_needsSave != needsSave) {
        _needsSave = needsSave;
        
        self.saveButtonItem.enabled = needsSave;
        
        if (needsSave) {
            
            [self.blog.managedObjectContext.undoManager beginUndoGrouping];
            
            NSString *title = NSLocalizedString(@"Discard", @"Menus button title for cancelling/discarding changes made.");
            UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:title style:UIBarButtonItemStylePlain target:self action:@selector(discardChangesBarButtonItemPressed:)];
            [self.navigationItem setLeftBarButtonItem:button animated:YES];
            [self.navigationItem setHidesBackButton:YES animated:YES];
            
        } else {
            
            [self.blog.managedObjectContext.undoManager endUndoGrouping];
            
            [self.navigationItem setLeftBarButtonItem:nil animated:YES];
            [self.navigationItem setHidesBackButton:NO animated:YES];
        }
    }
}

- (void)setIsSaving:(BOOL)isSaving
{
    if (_isSaving != isSaving) {
        _isSaving = isSaving;
        if (isSaving) {
            UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:NSLocalizedString(@"Saving...", @"Menus save button title while it is saving a Menu.") style:UIBarButtonItemStylePlain target:nil action:nil];
            [self.navigationItem setRightBarButtonItem:button animated:YES];
        } else {
            [self.navigationItem setRightBarButtonItem:self.saveButtonItem animated:YES];
        }
    }
}

- (void)discardAllChanges
{
    // Clear saving/changes states.
    [self setNeedsSave:NO forMenu:nil significantChanges:NO];
    
    // Trigger the undo.
    [self.blog.managedObjectContext.undoManager undo];
    [self reloadMenusViews];
    
    // Restore the top offset.
    CGPoint offset = self.scrollView.contentOffset;
    offset.y = 0;
    // Scroll to the top on the next run-loop so the layout finishes updating before scrolling.
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.scrollView setContentOffset:offset animated:YES];
    });
}

- (BOOL)defaultMenuEnabledForSelectedLocation
{
    return self.selectedMenuLocation == [self.blog.menuLocations firstObject];
}

- (NSString *)generateIncrementalMenuName
{
    NSInteger highestInteger = 0;
    for (Menu *menu in self.blog.menus) {
        if (!menu.name.length) {
            continue;
        }
        NSString *nameNumberStr;
        NSScanner *numberScanner = [NSScanner scannerWithString:menu.name];
        NSCharacterSet *characterSet = [NSCharacterSet decimalDigitCharacterSet];
        [numberScanner scanUpToCharactersFromSet:characterSet intoString:NULL];
        [numberScanner scanCharactersFromSet:characterSet intoString:&nameNumberStr];
        
        if ([nameNumberStr integerValue] > highestInteger) {
            highestInteger = [nameNumberStr integerValue];
        }
    }
    highestInteger = highestInteger + 1;
    NSString *menuStr = NSLocalizedString(@"Menu", @"The default text used for filling the name of a menu when creating it.");
    return [NSString stringWithFormat:@"%@ %i", menuStr, highestInteger];
}

- (MenuItemEditingViewController *)editingControllerWithItem:(MenuItem *)item
{
    MenuItemEditingViewController *controller = [[MenuItemEditingViewController alloc] initWithItem:item blog:self.blog];
    void(^dismiss)() = ^() {
        [self dismissViewControllerAnimated:YES completion:nil];
    };
    controller.onSelectedToSave = ^() {
        [self setNeedsSave:YES forMenu:self.selectedMenuLocation.menu significantChanges:YES];
        [self.itemsView refreshViewWithItem:item focus:YES];
        dismiss();
    };
    controller.onSelectedToTrash = ^() {
        if (item.itemID.integerValue) {
            // If the item had an ID, saving is enabled.
            // Otherwise the item was local only.
            [self setNeedsSave:YES forMenu:self.selectedMenuLocation.menu significantChanges:YES];
        }
        [self.itemsView removeItem:item];
        [self insertBlankMenuItemIfNeeded];
        dismiss();
    };
    controller.onSelectedToCancel = dismiss;
    return controller;
}

#pragma mark - Bar button items

- (void)discardChangesBarButtonItemPressed:(id)sender
{
    [self promptForDiscardingChangesByTheLeftBarButtonItem:^{
        [self discardAllChanges];
    } cancellation:nil];
}

- (void)saveBarButtonItemPressed:(id)sender
{
    [self.detailsView resignFirstResponder];
    
    // Buckle up, we gotta save this Menu!
    Menu *menuToSave = self.updatedMenuForSaving ?: self.selectedMenuLocation.menu;
    
    BOOL defaultMenuEnabled = [self defaultMenuEnabledForSelectedLocation];
    
    // Check if user is trying to save the Default Menu and made changes to it.
    if (menuToSave.menuID.integerValue == MenuDefaultID && defaultMenuEnabled && self.hasMadeSignificantMenuChanges) {
        
        // Create a new menu to use instead of the Default Menu.
        Menu *newMenu = [Menu newMenu:self.blog.managedObjectContext];
        newMenu.blog = self.blog;
        if ([menuToSave.name isEqualToString:[Menu defaultMenuName]]) {
            // Don't use "Default Menu" as the name of the menu.
            newMenu.name = [self generateIncrementalMenuName];
        } else {
            newMenu.name = menuToSave.name;
        }
        
        Menu *defaultMenu = menuToSave;
        // We'll save the newMenu instead.
        menuToSave = newMenu;
        // Use the items the user customized on the Default Menu as the items on the newMenu to save.
        menuToSave.items = defaultMenu.items;
        
        // Reset the Default Menu.
        defaultMenu.items = nil;
        defaultMenu.name = [Menu defaultMenuName];
        
        // Add and select the new Menu in the UI.
        self.selectedMenuLocation.menu = menuToSave;
        [self.headerView addMenu:menuToSave];
        [self.headerView setSelectedMenu:menuToSave];
        [self setViewsWithMenu:menuToSave];
    }
    
    __weak __typeof(self) weakSelf = self;
    
    void(^toggleIsSaving)(BOOL) = ^(BOOL saving) {
        // Disable user interaction while we are processing the save.
        weakSelf.scrollView.userInteractionEnabled = !saving;
        // Toggle the detailsView button for "Saving...".
        weakSelf.isSaving = saving;
    };
    
    void(^failureToSave)(NSError *) = ^(NSError *error) {
        toggleIsSaving(NO);
        // Present the error message.
        NSString *errorTitle = NSLocalizedString(@"Error Saving Menu", @"Menus error title for a menu that received an error while trying to save a menu.");
        [WPError showNetworkingAlertWithError:error title:errorTitle];
    };
    
    void(^updateMenu)() = ^() {
        [weakSelf.menusService updateMenu:menuToSave
                                  forBlog:weakSelf.blog
                                  success:^() {
                                      // Refresh the items stack since the items may have changed.
                                      [weakSelf.itemsView reloadItems];
                                      toggleIsSaving(NO);
                                      [weakSelf setNeedsSave:NO forMenu:nil significantChanges:NO];
                                  }
                                  failure:failureToSave];
    };
    
    toggleIsSaving(YES);
    
    if (menuToSave.menuID.integerValue == 0 && defaultMenuEnabled) {
        // Need to create the menu first.
        [self.menusService createMenuWithName:menuToSave.name
                                         blog:self.blog
                                      success:^(NSNumber *menuID) {
                                          // Set the new menuID and continue the update.
                                          menuToSave.menuID = menuID;
                                          updateMenu();
                                      }
                                      failure:failureToSave];
    } else {
        // Update the menu.
        updateMenu();
    }
}

#pragma mark - MenusHeaderViewDelegate

- (void)headerView:(MenusHeaderView *)headerView selectedLocation:(MenuLocation *)location
{
    if (location == self.selectedMenuLocation) {
        // Ignore, already selected this location.
        return;
    }
    
    void(^selectLocation)() = ^() {
        
        self.selectedMenuLocation = location;
        
        // Update the default menu option.
        Menu *defaultMenu = [Menu defaultMenuForBlog:self.blog];
        if ([self defaultMenuEnabledForSelectedLocation]) {
            // Is primary menu location, allow the option of the default generated Menu.
            defaultMenu.name = [Menu defaultMenuName];
        } else {
            // Default menu is a "No Menu" nullable option when not using the primary location.
            defaultMenu.name = NSLocalizedString(@"No Menu", @"Menus selection title for setting a location to not use a menu.");
        }
        [self.headerView refreshMenuViewsUsingMenu:defaultMenu];
        
        [self.headerView setSelectedLocation:location];
        [self.headerView setSelectedMenu:location.menu];
        [self setViewsWithMenu:location.menu];
    };
    
    if (self.needsSave) {
        [self promptForDiscardingChangesBeforeSelectingADifferentLocation:^{
            [self discardAllChanges];
            selectLocation();
        } cancellation:nil];
    } else {
        selectLocation();
    }
}

- (void)headerView:(MenusHeaderView *)headerView selectedMenu:(Menu *)menu
{
    if (menu == self.selectedMenuLocation.menu) {
        // Ignore, already selected this menu.
        return;
    }
    
    void(^selectMenu)() = ^() {
        
        Menu *defaultMenu = [Menu defaultMenuForBlog:self.blog];
        if (menu == defaultMenu) {
            /*
             * Special case for the user selecting "Default Menu" or "No Menu" in which we need
             * to save the previously selected menu to save it without a location.
             */
            [self setNeedsSave:YES forMenu:self.selectedMenuLocation.menu significantChanges:NO];
        } else {
            [self setNeedsSave:YES forMenu:menu significantChanges:NO];
        }
        
        self.selectedMenuLocation.menu = menu;
        [self.headerView setSelectedMenu:menu];
        [self setViewsWithMenu:menu];
    };
    
    if (self.needsSave && self.hasMadeSignificantMenuChanges) {
        
        [self promptForDiscardingChangesBeforeSelectingADifferentMenu:^{
            [self discardAllChanges];
            selectMenu();
        } cancellation:nil];
        
    } else {
        selectMenu();
    }
}

- (void)headerViewSelectedForCreatingNewMenu:(MenusHeaderView *)headerView
{
    void(^createMenu)() = ^() {
        
        Menu *newMenu = [Menu newMenu:self.blog.managedObjectContext];
        newMenu.blog = self.blog;
        newMenu.name = [self generateIncrementalMenuName];
        self.selectedMenuLocation.menu = newMenu;
        
        [self.headerView addMenu:newMenu];
        [self.headerView setSelectedMenu:newMenu];
        [self setViewsWithMenu:newMenu];
        
        [self setNeedsSave:YES forMenu:newMenu significantChanges:YES];
    };
    
    if (self.needsSave && self.hasMadeSignificantMenuChanges) {
        
        [self promptForDiscardingChangesBeforeCreatingNewMenu:^{
            [self discardAllChanges];
            createMenu();
        } cancellation:nil];
        
    } else {
        createMenu();
    }
}

#pragma mark - MenuDetailsViewDelegate

- (void)detailsViewUpdatedMenuName:(MenuDetailsView *)menuDetailView
{
    [self.headerView refreshMenuViewsUsingMenu:menuDetailView.menu];
    [self setNeedsSave:YES forMenu:menuDetailView.menu significantChanges:YES];
}

- (void)detailsViewSelectedToDeleteMenu:(MenuDetailsView *)menuDetailView
{
    Menu *menuToDelete = menuDetailView.menu;
    __weak __typeof(self) weakSelf = self;
    
    void(^selectDefaultMenu)() = ^() {
        Menu *defaultMenu =[Menu defaultMenuForBlog:weakSelf.blog];
        weakSelf.selectedMenuLocation.menu = defaultMenu;
        [weakSelf.headerView setSelectedMenu:defaultMenu];
        [weakSelf setViewsWithMenu:defaultMenu];
    };
    
    void(^removeMenuFromUI)() = ^() {
        [weakSelf.headerView removeMenu:menuToDelete];
    };
    
    void(^restoreMenuToUI)() = ^() {
        [weakSelf.headerView addMenu:menuToDelete];
    };
    
    void(^deleteMenu)() = ^() {
        [weakSelf.menusService deleteMenu:menuToDelete
                                  forBlog:weakSelf.blog
                                  success:^{
                                      [weakSelf setNeedsSave:NO forMenu:nil significantChanges:NO];
                                  }
                                  failure:^(NSError *error) {
                                      // Add the menu back to the list.
                                      restoreMenuToUI();
                                      // Present the error message.
                                      NSString *errorTitle = NSLocalizedString(@"Error Deleting Menu", @"Menus error title for a menu that received an error while trying to delete it.");
                                      [WPError showNetworkingAlertWithError:error title:errorTitle];
                                  }];
    };
    
    NSString *alertTitle = NSLocalizedString(@"Are you sure you want to delete the menu?", @"Menus confirmation text for confirming if a user wants to delete a menu.");
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:alertTitle
                                                                             message:nil
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *confirmTitle = NSLocalizedString(@"Delete Menu", @"Menus confirmation button for deleting a menu.");
    NSString *cancelTitle = NSLocalizedString(@"Cancel", @"Menus cancel button for deleting a menu.");
    UIAlertAction *confirmAction = [UIAlertAction actionWithTitle:confirmTitle
                                                          style:UIAlertActionStyleDestructive
                                                        handler:^(UIAlertAction * _Nonnull action) {
                                                            selectDefaultMenu();
                                                            removeMenuFromUI();
                                                            deleteMenu();
                                                        }];
    [alertController addAction:confirmAction];
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:cancelTitle
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil];
    [alertController addAction:cancelAction];
    [self presentViewController:alertController animated:YES completion:nil];
}

#pragma mark - MenuItemsViewControllerDelegate

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController createdNewItemForEditing:(MenuItem *)item
{
    MenuItemEditingViewController *controller = [self editingControllerWithItem:item];
    controller.onSelectedToCancel = controller.onSelectedToTrash;
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController selectedItemForEditing:(MenuItem *)item
{
    MenuItemEditingViewController *controller = [self editingControllerWithItem:item];
    [self presentViewController:controller animated:YES completion:nil];
}

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController didUpdateMenuItemsOrdering:(Menu *)menu
{
    [self setNeedsSave:YES forMenu:menu significantChanges:YES];
}

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController requiresScrollingToCenterView:(UIView *)viewForScrolling
{
    CGRect visibleRect = [self.scrollView convertRect:viewForScrolling.frame fromView:viewForScrolling.superview];
    visibleRect.origin.y -= (self.scrollView.frame.size.height - visibleRect.size.height) / 2.0;
    visibleRect.size.height = self.scrollView.frame.size.height;
    [self.scrollView scrollRectToVisible:visibleRect animated:YES];
}

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController prefersScrollingEnabled:(BOOL)enabled
{
    self.scrollView.scrollEnabled = enabled;
}

- (void)itemsViewController:(MenuItemsViewController *)itemsViewController prefersAdjustingScrollingOffsetForAnimatingView:(UIView *)view
{
    // adjust the scrollView offset to ensure this view is easily viewable
    const CGFloat padding = 10.0;
    CGRect viewRectWithinScrollViewWindow = [self.scrollView.window convertRect:view.frame fromView:view.superview];
    CGRect visibleContentRect = [self.scrollView.window convertRect:self.scrollView.frame fromView:self.view];
    
    CGPoint offset = self.scrollView.contentOffset;
    
    visibleContentRect.origin.y += offset.y;
    viewRectWithinScrollViewWindow.origin.y += offset.y;
    
    BOOL updated = NO;
    
    if (viewRectWithinScrollViewWindow.origin.y < visibleContentRect.origin.y + padding) {
        
        offset.y -= viewRectWithinScrollViewWindow.size.height;
        updated = YES;
        
    } else  if (viewRectWithinScrollViewWindow.origin.y + viewRectWithinScrollViewWindow.size.height > (visibleContentRect.origin.y + visibleContentRect.size.height) - padding) {
        offset.y += viewRectWithinScrollViewWindow.size.height;
        updated = YES;
    }
    
    if (updated) {
        [UIView animateWithDuration:0.25 animations:^{
            self.scrollView.contentOffset = offset;
        }];
    }
}

- (void)itemsViewAnimatingContentSizeChanges:(MenuItemsViewController *)itemsView focusedRect:(CGRect)focusedRect updatedFocusRect:(CGRect)updatedFocusRect
{
    CGPoint offset = self.scrollView.contentOffset;
    offset.y += updatedFocusRect.origin.y - focusedRect.origin.y;
    self.scrollView.contentOffset = offset;
}

#pragma mark - Alert Handlers

- (NSString *)discardChangesAlertTitle
{
    return NSLocalizedString(@"Unsaved Changes", @"Menus alert title for alerting the user to unsaved changes.");
}

- (void)promptForDiscardingChangesBeforeSelectingADifferentLocation:(void(^)())confirmationBlock
                                                       cancellation:(void(^)())cancellationBlock
{
    NSString *title = [self discardChangesAlertTitle];
    NSString *message = NSLocalizedString(@"Selecting a different menu location will discard changes you've made to the current menu. Are you sure you want to continue?", @"Menus alert message for alerting the user to unsaved changes while trying to select a different menu location.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel and Keep Changes", @"Menus alert button title to cancel discarding changes and not select a new menu location")
                                                         style:UIAlertActionStyleCancel
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (cancellationBlock) {
                                                               cancellationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Discard and Select Location", @"Menus alert button title to continue selecting a menu location and discarding current changes.")
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (confirmationBlock) {
                                                               confirmationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForDiscardingChangesBeforeSelectingADifferentMenu:(void(^)())confirmationBlock
                                                   cancellation:(void(^)())cancellationBlock
{
    NSString *title = [self discardChangesAlertTitle];
    NSString *message = NSLocalizedString(@"Selecting a different menu will discard changes you've made to the current menu. Are you sure you want to continue?", @"Menus alert message for alerting the user to unsaved changes while trying to select a different menu.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel and Keep Changes", @"Menus alert button title to cancel discarding changes and not select a new menu")
                                                         style:UIAlertActionStyleCancel
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (cancellationBlock) {
                                                               cancellationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Discard and Select Menu", @"Menus alert button title to continue selecting a menu and discarding current changes.")
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (confirmationBlock) {
                                                               confirmationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForDiscardingChangesBeforeCreatingNewMenu:(void(^)())confirmationBlock
                                           cancellation:(void(^)())cancellationBlock
{
    NSString *title = [self discardChangesAlertTitle];
    NSString *message = NSLocalizedString(@"Creating a new menu will discard changes you've made to the current menu. Are you sure you want to continue?", @"Menus alert message for alerting the user to unsaved changes while trying to create a new menu.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Cancel and Keep Changes", @"Menus alert button title to cancel discarding changes and not createa a new menu.")
                                                         style:UIAlertActionStyleCancel
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (cancellationBlock) {
                                                               cancellationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Discard and Create New Menu", @"Menus alert button title to continue creating a menu and discarding current changes.")
                                                         style:UIAlertActionStyleDefault
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (confirmationBlock) {
                                                               confirmationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)promptForDiscardingChangesByTheLeftBarButtonItem:(void(^)())confirmationBlock
                                            cancellation:(void(^)())cancellationBlock
{
    NSString *title = [self discardChangesAlertTitle];
    NSString *message = NSLocalizedString(@"Are you sure you want to cancel and discard changes?", @"Menus alert message for alerting the user to unsaved changes while trying back out of Menus.");
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Continue Working", @"Menus alert button title to continue making changes.")
                                                         style:UIAlertActionStyleCancel
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (cancellationBlock) {
                                                               cancellationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    {
        UIAlertAction *action = [UIAlertAction actionWithTitle:NSLocalizedString(@"Discard Changes", @"Menus alert button title to discard changes.")
                                                         style:UIAlertActionStyleDestructive
                                                       handler:^(UIAlertAction * _Nonnull action) {
                                                           if (confirmationBlock) {
                                                               confirmationBlock();
                                                           }
                                                       }];
        [alert addAction:action];
    }
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - notifications

- (void)updateWithKeyboardNotification:(NSNotification *)notification
{
    CGRect frame = [[notification.userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    frame = [self.view.window convertRect:frame toView:self.view];
    
    CGFloat insetPadding = 10.0;
    UIEdgeInsets inset = self.scrollView.contentInset;
    UIEdgeInsets scrollInset = self.scrollView.scrollIndicatorInsets;
    
    if (frame.origin.y > self.view.frame.size.height) {
        inset.bottom = 0.0;
        scrollInset.bottom = 0.0;
    } else  {
        inset.bottom = self.view.frame.size.height - frame.origin.y;
        scrollInset.bottom = inset.bottom;
        inset.bottom += insetPadding;
    }
    self.scrollView.contentInset = inset;
    self.scrollView.scrollIndicatorInsets = scrollInset;
}

- (void)keyboardWillHideNotification:(NSNotification *)notification
{
    self.observesKeyboardChanges = NO;
    
    UIEdgeInsets inset = self.scrollView.contentInset;
    UIEdgeInsets scrollInset = self.scrollView.scrollIndicatorInsets;
    inset.bottom = 0;
    scrollInset.bottom = 0;
    self.scrollView.contentInset = inset;
    self.scrollView.scrollIndicatorInsets = scrollInset;
}

- (void)keyboardWillShowNotification:(NSNotification *)notification
{
    self.observesKeyboardChanges = YES;
    [self updateWithKeyboardNotification:notification];
}

- (void)keyboardWillChangeFrameNotification:(NSNotification *)notification
{
    if (self.observesKeyboardChanges) {
        [self updateWithKeyboardNotification:notification];
    }
}

@end