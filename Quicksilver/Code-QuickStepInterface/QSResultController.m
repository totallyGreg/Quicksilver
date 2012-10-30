

#import "QSPreferenceKeys.h"
#import "QSAction.h"
#import "QSObject.h"
#import "QSResultController.h"
#import "QSSearchObjectView.h"

#import "QSInterfaceController.h"
#import "QSIconLoader.h"
#import "QSLibrarian.h"
#import "QSWindow.h"

#import "AppKitPrivate.h"
#import "QSImageAndTextCell.h"
#import "QSRankCell.h"
#import "QSObjectCell.h"

#import "QSObject_Menus.h"

#define MAX_VISIBLE_COLUMNS 4
#define COLUMNID_TYPE		@"TypeColumn"
#define COLUMNID_NAME		@"NameColumn"
#define COLUMNID_RANK	 	@"RankColumn"
#define COLUMNID_HASCHILDREN	@"hasChildren"
#define COLUMNID_EQUIV	 	@"EquivColumn"

#define IconLoadNotification @"IconsLoaded"

// These should be localizable, but I'm not sure how to do that
#define filterResultsString @"Filter Results"
#define filterCatalogString @"Filter Catalog"
#define snapToBestString @"Snap to Best"

#import "QSTextProxy.h"

NSMutableDictionary *kindDescriptions = nil;

@interface QSResultController ()
- (void)reloadColors;
@end

@implementation QSResultController

@synthesize resultTable=resultTable;

+ (void)initialize {
    if (!kindDescriptions)
        kindDescriptions = [[NSMutableDictionary alloc] initWithContentsOfFile:
                            [[NSBundle mainBundle] pathForResource:@"QSKindDescriptions" ofType:@"plist"]];
}

+ (id)sharedInstance {
	static id _sharedInstance;
	if (!_sharedInstance) _sharedInstance = [[[self class] allocWithZone:[self zone]] init];
	return _sharedInstance;
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([keyPath isEqualToString:@"values.QSAppearance3B"]) {
        [self reloadColors];
    } else if ([keyPath isEqualToString:@"rowHeight"]) {
        if ([change objectForKey:NSKeyValueChangeNewKey]) {
            [(QSObjectCell *)[[resultTable tableColumnWithIdentifier: COLUMNID_NAME] dataCell] setShowDetails:([[change objectForKey:NSKeyValueChangeNewKey] doubleValue] >= 34.0)];
        }
    }
}

#pragma mark -
#pragma mark Lifetime
- (id)init {
	self = [self initWithWindowNibName:@"ResultWindow"];
	if (self) {
        focus = nil;
		loadingIcons = NO;
		loadingChildIcons = NO;
		iconTimer = nil;
		childrenLoadTimer = nil;
		selectedItem = nil;
		loadingRange = NSMakeRange(0, 0);
		scrollViewTrackingRect = 0;
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(objectIconModified:) name:QSObjectIconModified object:nil];
	}
	return self;
}

- (id)initWithFocus:(id)myFocus {
    self = [self init];
    if (self) {
        focus = myFocus;
	}
    return self;
}

- (void)windowDidLoad {
	[(QSWindow *)[self window] setHideOffset:NSMakePoint(32, 0)];
	[(QSWindow *)[self window] setShowOffset:NSMakePoint(16, 0)];
	[self setupResultTable];
	// [[[self window] contentView] flipSubviewsOnAxis:1];

	[splitView setAutosaveName:@"QSResultWindowSplitView"];
    
	if (![[NSUserDefaults standardUserDefaults] boolForKey:@"QSResultsShowChildren"]) {
		NSView *tableView = [resultTable enclosingScrollView];
		[[tableView retain] autorelease];
		[tableView removeFromSuperview];
		[tableView setFrame:[splitView frame]];
		[tableView setAutoresizingMask:[splitView autoresizingMask]];

		[[splitView superview] addSubview:tableView];
		resultChildTable = nil;
		[splitView removeFromSuperview];
	}
    NSUserDefaultsController *sucd = [NSUserDefaultsController sharedUserDefaultsController];
    [sucd addObserver:self
           forKeyPath:@"values.QSAppearance3B"
              options:0
              context:nil];
    
	[[[resultTable tableColumnWithIdentifier:@"NameColumn"] dataCell] bind:@"textColor"
                                                                  toObject:sucd
                                                               withKeyPath:@"values.QSAppearance3T"
                                                                   options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:@"NSValueTransformerName"]];
    
	[resultTable bind:@"backgroundColor"
			 toObject:sucd
          withKeyPath:@"values.QSAppearance3B"
              options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName
                                                  forKey:@"NSValueTransformerName"]];
	[resultTable bind:@"highlightColor"
			 toObject:sucd
		 withKeyPath:@"values.QSAppearance3A"
			 options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName
												 forKey:@"NSValueTransformerName"]];
    [resultTable addObserver:self
           forKeyPath:@"rowHeight"
              options:NSKeyValueObservingOptionNew
              context:nil];
	if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QSResultsShowChildren"]) {
		[[[resultChildTable tableColumnWithIdentifier:@"NameColumn"] dataCell] bind:@"textColor"
                                                                           toObject:sucd
																		withKeyPath:@"values.QSAppearance3T"
																			options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName forKey:@"NSValueTransformerName"]];
		[resultChildTable bind:@"backgroundColor"
                      toObject:sucd
                   withKeyPath:@"values.QSAppearance3B"
                       options:[NSDictionary dictionaryWithObject:NSUnarchiveFromDataTransformerName
                                                           forKey:@"NSValueTransformerName"]];
	}
	[self reloadColors];
	[[self window] setLevel:NSFloatingWindowLevel+1];

	//[[resultTable enclosingScrollView] setHasVerticalScroller:NO];
}

- (void)dealloc {
	NSUserDefaultsController *sucd = [NSUserDefaultsController sharedUserDefaultsController];
	[sucd removeObserver:self forKeyPath:@"values.QSAppearance3B"];

	[[[resultTable tableColumnWithIdentifier:@"NameColumn"] dataCell] unbind:@"textColor"];
	[resultTable unbind:@"backgroundColor"];
	[resultTable unbind:@"highlightColor"];
	[resultChildTable unbind:@"backgroundColor"];

	[super dealloc];
}

#pragma mark -
#pragma mark Accessors, Utilities
- (NSArray *)currentResults { return currentResults; }
- (void)setCurrentResults:(NSArray *)newCurrentResults {
	[currentResults release];
	currentResults = [newCurrentResults retain];
}

- (QSObject *)selectedItem { return selectedItem; }
- (void)setSelectedItem:(QSObject *)newSelectedItem {
	if (selectedItem != newSelectedItem) {
		[selectedItem release];
		selectedItem = [newSelectedItem retain];
	}
}

- (void)reloadColors {
	NSData *data = [[NSUserDefaultsController sharedUserDefaultsController] valueForKeyPath:@"values.QSAppearance3B"];
	NSColor *color = [NSUnarchiver unarchiveObjectWithData:data];
	[[self window] setOpaque:[color alphaComponent] == 1.0f];
}

- (void)updateScrollViewTrackingRect {
	NSView *view = [[self window] contentView];
	if (scrollViewTrackingRect) [view removeTrackingRect:scrollViewTrackingRect];
	scrollViewTrackingRect = [view addTrackingRect:[view frame] owner:self userData:nil assumeInside:NO];
}

- (IBAction)setSearchFilterAllActivated {
	if ([filterCatalog state] == NSOffState) {
		[filterCatalog setState:NSOnState];
		[filterResults setState:NSOffState];
		[snapToBest setState:NSOffState];
		[searchModeField setStringValue:filterCatalogString];
	}
}

- (IBAction)setSearchFilterActivated {
	if ([filterResults state] == NSOffState) {
		[filterResults setState:NSOnState];
		[filterCatalog setState:NSOffState];
		[snapToBest setState:NSOffState];
		[searchModeField setStringValue:filterResultsString];
	}
}

- (IBAction)setSearchSnapActivated {
	if ([snapToBest state] == NSOffState) {
		[snapToBest setState:NSOnState];
		[filterResults setState:NSOffState];
		[filterCatalog setState:NSOffState];
		[searchModeField setStringValue:snapToBestString];
	}
}

- (IBAction)setSearchMode:(id)sender {
    [focus setSearchMode:[sender tag]];
}

- (IBAction)sortByName:(id)sender{
	[sortByName setState:NSOnState];
	[sortByScore setState:NSOffState];
    [focus sortByName:sender];
}

- (IBAction)sortByScore:(id)sender {
	[sortByName setState:NSOffState];
	[sortByScore setState:NSOnState];
    [focus sortByScore:sender];
}

- (void)bump:(NSInteger)i {
	NSRect frame = [[self window] frame];
	NSInteger j;
	for (j = 1; j <= 8; j++)
		[[self window] setFrameOrigin:NSOffsetRect(frame, i*j/8, 0) .origin];
	for (; j >= 0; j--)
		[[self window] setFrameOrigin:NSOffsetRect(frame, i*j/8, 0) .origin];
}

- (void)loadChildren {
	if (NSEqualRects(NSZeroRect, [resultChildTable visibleRect]) )
        return;
	[resultChildTable reloadData];
}

-(void)rowModified:(NSInteger)index {
	[resultTable setNeedsDisplayInRect:[resultTable rectOfRow:index]];
}

/*- (void)setSplitLocation {
	NSNumber *resultWidth = [[NSUserDefaults standardUserDefaults] objectForKey:kResultTableSplit];
    
	if (resultWidth) {
		NSView *firstView = [[splitView subviews] objectAtIndex:0];
		NSRect frame = [firstView frame];
		frame.size.width = [resultWidth floatValue] *NSWidth([splitView frame]);
        
		NSLog(@"%f", frame.size.width);
        
		[firstView setFrame:frame];
        
		frame.origin.x += NSWidth(frame);
		frame.size.width = NSWidth([splitView frame]) - NSWidth(frame) - [splitView dividerThickness];
        
		[[[splitView subviews] lastObject] setFrame:frame];
        
		[splitView adjustSubviews];
		[splitView display];
	}
}*/

#pragma mark -
#pragma mark Icon Loading

- (void)iconLoader:(QSIconLoader *)loader loadedIndex:(NSInteger)m inArray:(NSArray *)array {
	//	NSLog(@"loaded");
	NSTableView *table = nil;
	if (loader == resultIconLoader) {
		table = resultTable;
		if (m == [resultTable selectedRow])
            [focus setNeedsDisplay:YES];
	} else if (loader == resultChildIconLoader) {
		table = resultChildTable;
	} else {
		//NSLog(@"RogueLoader %d", m);
	}
	[table setNeedsDisplay:YES];
}

- (BOOL)iconsAreLoading {
    BOOL resultsIconLoading = [resultIconLoader isLoading];
    return (resultsIconLoading ? YES : [resultChildIconLoader isLoading]);
}

- (QSIconLoader *)resultIconLoader {
	if (!resultIconLoader) {
		[self setResultIconLoader:[QSIconLoader loaderWithArray:[self currentResults]]];
		[resultIconLoader setDelegate:self];
	}
	return [[resultIconLoader retain] autorelease];
}

- (void)setResultIconLoader:(QSIconLoader *)aResultIconLoader {
	//NSLog(@"setloader %@", aResultIconLoader);
	if (resultIconLoader != aResultIconLoader) {
		[resultIconLoader invalidate];
		[resultIconLoader release];
		resultIconLoader = [aResultIconLoader retain];
	}
}

- (QSIconLoader *)resultChildIconLoader {
    if (!resultChildIconLoader) {
        [self setResultChildIconLoader:[QSIconLoader loaderWithArray:[selectedItem children]]];
        [resultChildIconLoader setDelegate:self];
    }
    return [[resultChildIconLoader retain] autorelease];
}

- (void)setResultChildIconLoader:(QSIconLoader *)aResultChildIconLoader {
	if (resultChildIconLoader != aResultChildIconLoader) {
		[resultChildIconLoader invalidate];
		[resultChildIconLoader release];
		resultChildIconLoader = [aResultChildIconLoader retain];
	}
}

- (void)objectIconModified:(NSNotification *)notif
{
    // if results are showing, check for icons that need updating
    if ([[self window] isVisible]) {
        QSObject *object = [notif object];
        // if updated object is is in the results, update it in the list
        NSUInteger ind = [currentResults indexOfObject:object];
        if (ind != NSNotFound) {
            [self rowModified:ind];
        }
        // if updated object is is in the child results, update it in the list
        if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QSResultsShowChildren"]) {
            ind = [[[self selectedItem] children] indexOfObject:object];
            if (ind != NSNotFound) {
                [resultChildTable setNeedsDisplayInRect:[resultChildTable rectOfRow:ind]];
            }
        }
    }
}

#pragma mark -
#pragma mark Actions
- (IBAction)defineMnemonic:(id)sender {
	//	NSLog(@"%d", [resultTable clickedRow]);
	if (![focus mnemonicDefined])
		[focus defineMnemonic:sender];
	else
		[focus removeMnemonic:sender];
}

- (IBAction)setScore:(id)sender {return;}

- (IBAction)clearMnemonics:(id)sender {
	[focus removeImpliedMnemonic:sender];
}

- (IBAction)omitItem:(id)sender {
	[[QSLibrarian sharedInstance] setItem:[focus objectValue] isOmitted:YES];
}

- (IBAction)assignAbbreviation:(id)sender {
	[[QSLibrarian sharedInstance] assignCustomAbbreviationForItem:[focus objectValue]];
}

- (void)arrayChanged:(NSNotification*)notif {
	[self setResultIconLoader:nil];
	[self setCurrentResults:[focus resultArray]];
    
	[resultTable reloadData];
    
	//visibleRange = [resultTable rowsInRect:[resultTable visibleRect]];
	//	NSLog(@"arraychanged %d", [[self currentResults] count]);
	//[self threadedIconLoad];
    [[self resultIconLoader] loadIconsInRange:[resultTable rowsInRect:[resultTable visibleRect]]];
}

- (void)updateSelectionInfo {
	selectedResult = [resultTable selectedRow];
    
	if (selectedResult < 0 || ![[self currentResults] count]) return;
	QSObject *newSelectedItem = [[self currentResults] objectAtIndex:selectedResult];
    
	if (selectedItem != newSelectedItem) {
		[self setSelectedItem:newSelectedItem];
		[resultChildTable noteNumberOfRowsChanged];
        // HenningJ 20110419 there is no localized version of "%d of %d". Additionally, something goes wrong while trying to localize it.
        // NSString *fmt = NSLocalizedStringFromTableInBundle(@"%d of %d", nil, [NSBundle bundleForClass:[self class]], @"");
        NSString *status = [NSString stringWithFormat:@"%ld of %ld", (long)selectedResult + 1, (long)[[self currentResults] count]];
        if ([resultTable rowHeight] < 34 && [selectedItem details]) {
            status = [status stringByAppendingFormat:@" %C %@", (unsigned short)0x25B8, [selectedItem details]];
        }
        [(NSTextField *)selectionView setStringValue:status];
        
		if ([[NSApp currentEvent] modifierFlags] & NSFunctionKeyMask && [[NSApp currentEvent] isARepeat]) {
			if ([childrenLoadTimer isValid]) {
				[childrenLoadTimer setFireDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
			} else {
				// ***warning  * this should be triggered by the keyUp
                if (![NSApp nextEventMatchingMask:NSKeyUpMask untilDate:[NSDate dateWithTimeIntervalSinceNow:0.333] inMode:NSDefaultRunLoopMode dequeue:NO]) {
                    [childrenLoadTimer release];
                    childrenLoadTimer = [[NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(loadChildren) userInfo:nil repeats:NO] retain];
                }
			}
		} else {
			[self loadChildren];
		}
	}

    /* Restart the icon loading for the children view */
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"QSResultsShowChildren"]) {
        [self setResultChildIconLoader:nil];
        [[self resultChildIconLoader] loadIconsInRange:[resultChildTable rowsInRect:[resultChildTable visibleRect]]];
    }
}

#pragma mark -
#pragma mark NSResponder
//- (void)scrollWheel:(NSEvent *)theEvent {
//	[resultTable scrollWheel:theEvent];
//}

- (void)keyDown:(NSEvent *)theEvent {
	NSString *characters;
	unichar c;
	NSUInteger characterIndex, characterCount;

	// There could be multiple characters in the event.
	characters = [theEvent charactersIgnoringModifiers];

	characterCount = [characters length];
	for (characterIndex = 0; characterIndex < characterCount;
		 characterIndex++) {
		c = [characters characterAtIndex: characterIndex];
		switch(c) {

			case '\r': //Return
					  //[self sendAction:[self action] to:[self target]];
				[[focus controller] executeCommand:self];
				break;
			case '\t': //Tab
			case 25: //Back Tab
			case 27: //Escape
				[[self window] orderOut:self];
				[focus keyDown:theEvent];
				return;
		}
	}

}

#pragma mark -
#pragma mark NSWindow Delegate
// called twice when a user resized the results window
- (void)windowDidResize:(NSNotification *)aNotification {
    [[self resultIconLoader] loadIconsInRange:[resultTable rowsInRect:[resultTable visibleRect]]];
	if (!NSEqualRects(NSZeroRect, [resultChildTable visibleRect]) && [self numberOfRowsInTableView:resultChildTable])
		[[self resultChildIconLoader] loadIconsInRange:[resultChildTable rowsInRect:[resultChildTable visibleRect]]];

	[self updateScrollViewTrackingRect];

	// saves size for result window when it is resized
	[[self window] saveFrameUsingName:@"QSResultWindow"];
}

#pragma mark -
#pragma mark NSSplitView Delegate
- (CGFloat) splitView:(NSSplitView *)sender constrainMaxCoordinate:(CGFloat)proposedMax ofSubviewAt:(NSInteger)offset {
	//NSLog(@"constrainMax: %f, %d", proposedMax, offset);
	// return proposedMax-36;
	return proposedMax; // - 165;
}

- (CGFloat) splitView:(NSSplitView *)sender constrainMinCoordinate:(CGFloat)proposedMin ofSubviewAt:(NSInteger)offset {
	//NSLog(@"constrainMin: %f, %d", proposedMin, offset);
	return NSWidth([sender frame]) / 2;
}

- (BOOL)splitView:(NSSplitView *)sender canCollapseSubview:(NSView *)subview {
	//NSLog(@"collapse");
	return subview != [resultTable enclosingScrollView];
	// if (subview == infoBox) return YES;
	// else return NO;
}

- (void)splitView:(NSSplitView *)sender resizeSubviewsWithOldSize:(NSSize)oldSize {
	CGFloat dividerThickness = [sender dividerThickness];
	id sv1 = [[sender subviews] objectAtIndex:0];
	id sv2 = [[sender subviews] objectAtIndex:1];
	NSRect leftFrame = [sv1 frame];
	NSRect rightFrame = [sv2 frame];
	NSRect newFrame = [sender frame];

	// if (sender != m_SourceItemSplitView) return;

	leftFrame.origin = NSMakePoint(0, 0);
	leftFrame.size.height = newFrame.size.height;
	rightFrame.size.height = newFrame.size.height;

	rightFrame.size.width = MIN(rightFrame.size.width, newFrame.size.width/2);
	if (rightFrame.size.width < 32) rightFrame.size.width = 0;

	leftFrame.size.width = newFrame.size.width - rightFrame.size.width - dividerThickness;

	rightFrame.origin = NSMakePoint(leftFrame.size.width + dividerThickness, 0);

	[sv1 setFrame:leftFrame];
	[sv2 setFrame:rightFrame];
}

- (void)splitViewDidResizeSubviews:(NSNotification *)notification {
	if ([[NSApp currentEvent] type] == NSLeftMouseDragged) {
        CGFloat split = NSWidth([[resultChildTable enclosingScrollView] frame]) / NSWidth([splitView frame]);
        [[NSUserDefaults standardUserDefaults] setFloat:split
                                                 forKey:kResultTableSplit];
    }
}
@end

@implementation QSResultController (Table)

//Table Methods

- (void)setupResultTable {
	//NSLog(@"setup result");
	NSTableColumn *tableColumn = nil;
	//  QSImageAndTextCell *imageAndTextCell = nil;
	//NSImageCell *imageCell = nil;

	[resultTable setTarget:self];

	[resultTable setAction:@selector(tableViewAction:)];
	[resultTable setDoubleAction:@selector(tableViewDoubleAction:)];
	[resultTable setVerticalMotionCanBeginDrag:NO];

	//	[resultTable setRowHeight:36];
	// imageAndTextCell = [[[QSImageAndTextCell alloc] init] autorelease];
	// [imageAndTextCell setEditable: YES];
	//  [imageAndTextCell setFont:[NSFont systemFontOfSize:11]];
	//  [imageAndTextCell setWraps:NO];
	//[imageAndTextCell setScrollable:YES];

	QSObjectCell *objectCell = [[[QSObjectCell alloc] init] autorelease];
	tableColumn = [resultTable tableColumnWithIdentifier: COLUMNID_NAME];
    if ([resultTable rowHeight] < 34.0) {
        [objectCell setShowDetails:NO];
    }
	[tableColumn setDataCell:objectCell];

	tableColumn = [resultChildTable tableColumnWithIdentifier: COLUMNID_NAME];
	[tableColumn setDataCell:objectCell];

	tableColumn = [resultTable tableColumnWithIdentifier: COLUMNID_RANK];

	NSCell *rankCell = [[[QSRankCell alloc] init] autorelease];
	[tableColumn setDataCell:rankCell];

	//[searchModePopUp setEnabled:fALPHA];

	tableColumn = [resultTable tableColumnWithIdentifier: COLUMNID_EQUIV];
	[[tableColumn dataCell] setFont:[NSFont systemFontOfSize:9]];
	[[tableColumn dataCell] setTextColor:[NSColor darkGrayColor]];

	[resultTable removeTableColumn:tableColumn];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(viewChanged:) name:NSViewBoundsDidChangeNotification object:[[resultTable enclosingScrollView] contentView]];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(childViewChanged:) name:NSViewBoundsDidChangeNotification object:[[resultChildTable enclosingScrollView] contentView]];
}

- (void)viewChanged:(NSNotification*)notif {
	NSRange newRange = [resultTable rowsInRect:[resultTable visibleRect]];
    
	//  NSLog(@"%d-%d are visible %d", visibleRange.location, visibleRange.location+visibleRange.length, [self iconsAreLoading]);
    
	//[self iconsAreLoading];
	//	NSBeep();
    [[self resultIconLoader] loadIconsInRange:newRange];
	//	[self threadedIconLoad];
    
	// loadingRange = newRange;
}

- (void)childViewChanged:(NSNotification*)notif {
	NSRange newRange = [resultChildTable rowsInRect:[resultChildTable visibleRect]];
	//visibleRange = [resultTable rowsInRect:[resultTable visibleRect]];
	//s NSLog(@"%d-%d are visible", visibleRange.location, visibleRange.location+visibleRange.length); /
	// [self threadedChildIconLoad];
    [[self resultChildIconLoader] loadIconsInRange:newRange];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
	if (tableView == resultChildTable) {
		return [[selectedItem children] count];
	} else {
		return [[self currentResults] count];
	}
}

- (BOOL)tableView:(NSTableView *)aTableView rowIsSeparator:(NSInteger)rowIndex {
	return NO;
}

- (BOOL)tableView:(NSTableView *)aTableView shouldDrawRow:(NSInteger)rowIndex inClipRect:(NSRect)clipRect {
	clipRect = [aTableView rectOfRow:rowIndex];
	// clipRect.origin.y += (int) (NSHeight(clipRect)/2);
	// clipRect.size.height = 1.0;
	[[NSColor colorWithDeviceWhite:0.95 alpha:1.0] set];

	NSRectFill(clipRect);

	id object = [[self currentResults] objectAtIndex:rowIndex];
	[[(QSObject *)object name] drawInRect:clipRect withAttributes:nil];

	return NO;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
	if (tableView == resultTable && [[self currentResults] count] > (NSUInteger)row) {
		QSObject *thisObject = [[self currentResults] objectAtIndex:row];

		if ([[tableColumn identifier] isEqualToString:COLUMNID_TYPE]) {
			NSString *kind = [thisObject kind];
			NSString *desc = [kindDescriptions objectForKey:kind];

			return (desc?desc:kind);
		}
		if ([[tableColumn identifier] isEqualToString:COLUMNID_NAME]) {
			return nil; //[[thisObject retain] autorelease];
		}
		if ([[tableColumn identifier] isEqualToString: COLUMNID_HASCHILDREN]) {

			return([thisObject hasChildren] ? [NSImage imageNamed:@"ChildArrow"] :nil);
		}

	}
	return nil;
}

- (void)tableView:(NSTableView *)aTableView willDisplayCell:(id)aCell forTableColumn:(NSTableColumn *)aTableColumn row:(NSInteger)rowIndex {
	if ([[aTableColumn identifier] isEqualToString:COLUMNID_NAME]) {
		NSArray *array = [self currentResults];
		if (aTableView == resultChildTable) array = [selectedItem children];
        
        // avoid attempting to access objects in a nonexistent array or an index out of bounds
        if (!array || rowIndex >= (NSInteger)[array count]) {
            return;
        }
		QSObject *thisObject = [array objectAtIndex:rowIndex];

		[aCell setRepresentedObject:thisObject];
        [aCell setState:[focus objectIsInCollection:thisObject]];
	}
	if ([[aTableColumn identifier] isEqualToString:COLUMNID_RANK]) {
		NSArray *array = [self currentResults];

        if (!array || rowIndex >= (NSInteger)[array count]) {
            return;
        }
		QSRankedObject *thisObject = [array objectAtIndex:rowIndex];

		[(QSRankCell *)aCell setScore:[thisObject score]];
		[(QSRankCell *)aCell setOrder:[thisObject order]];
		//int order = [thisObject order];
		// NSLog(@"score %f %@", score, thisObject);
		//return [thisObject retain]; //[NSNumber numberWithInt:(score*100) +order?1000:0];
	}
	return;
}
- (NSMenu *)tableView:(NSTableView*)tableView menuForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
	[tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:(row ? row : 0)] byExtendingSelection:NO];

	NSArray *array = [self currentResults];
	QSObject *thisObject = [array objectAtIndex:row];

    return [thisObject rankMenuWithTarget:focus];
}

- (BOOL)tableView:(NSTableView *)tv writeRows:(NSArray*)rows toPasteboard:(NSPasteboard*)pboard {
	[[[self currentResults] objectAtIndex:[[rows objectAtIndex:0] integerValue]]putOnPasteboard:pboard includeDataForTypes:nil];
	return YES;
}

- (void)tableViewSelectionDidChange:(NSNotification *)aNotification {
	if (aNotification && [aNotification object] != resultTable) return;

	if (selectedResult != -1 && selectedResult != [resultTable selectedRow]) {
		selectedResult = [resultTable selectedRow];
        [focus selectIndex:[resultTable selectedRow]];
		[self updateSelectionInfo];
	}
}

- (IBAction)tableViewAction:(id)sender {
	//NSLog(@"action %@ %d %d", sender, [sender clickedColumn] , [sender clickedRow]);
	if ([sender clickedRow] == -1) {

	} else if ([sender clickedColumn] == 0) {
		NSPoint origin = [sender rectOfRow:[sender clickedRow]].origin;
		origin.y += [sender rowHeight];
		NSEvent *theEvent = [NSEvent mouseEventWithType:NSRightMouseDown location:[sender convertPoint:origin toView:nil]
										modifierFlags:0 timestamp:0 windowNumber:[[sender window] windowNumber] context:nil eventNumber:0 clickCount:1 pressure:0];

	//	[tableView selectRow:row byExtendingSelection:NO];

		NSArray *array = [self currentResults];
		QSObject *thisObject = [array objectAtIndex:[sender clickedRow]];
        [NSMenu popUpContextMenu:[thisObject rankMenuWithTarget:focus] withEvent:theEvent forView:sender];

	}
}

- (IBAction)tableViewDoubleAction:(id)sender {
    [[focus controller] executeCommand:self];
}
@end
