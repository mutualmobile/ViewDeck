//
//  IIViewDeckController.h
//  IIViewDeck
//
//  Copyright (C) 2011, Tom Adriaenssen
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of
//  this software and associated documentation files (the "Software"), to deal in
//  the Software without restriction, including without limitation the rights to
//  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
//  of the Software, and to permit persons to whom the Software is furnished to do
//  so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

#import <UIKit/UIGestureRecognizerSubclass.h>

#import "IIViewDeckBezelGestureRecognizer.h"

@interface IIViewDeckBezelGestureRecognizer ()

@property (nonatomic, assign) IIViewDeckBezelPosition bezelPosition;

@end

CGFloat const kBezelGraceArea = 20.0f;

@implementation IIViewDeckBezelGestureRecognizer

- (instancetype)initWithTarget:(id)target
                        action:(SEL)action
              withViewDeckSide:(IIViewDeckBezelPosition)bezelPosition;
{
    self = [super initWithTarget:target action:action];

    if (self) {
        [self setBezelPosition:bezelPosition];
    }

    return self;
}

- (void)touchesBegan:(NSSet *)touches
           withEvent:(UIEvent *)event
{
    [super touchesBegan:touches withEvent:event];

    CGPoint touchedPoint = [[touches anyObject] locationInView:self.view];

    if (self.bezelPosition == IIViewDeckBezelPositionLeftAndRight) {
        if (touchedPoint.x > kBezelGraceArea && touchedPoint.x < self.view.bounds.size.width - kBezelGraceArea) {
            [self setState:UIGestureRecognizerStateFailed];
        }
    } else {
        if (self.bezelPosition == IIViewDeckBezelPositionRight) {
            if (touchedPoint.x < self.view.bounds.size.width - kBezelGraceArea) {
                [self setState:UIGestureRecognizerStateFailed];
            }
        } else if (self.bezelPosition == IIViewDeckBezelPositionLeft) {
            if (touchedPoint.x > kBezelGraceArea) {
                [self setState:UIGestureRecognizerStateFailed];
            }
        }
    }
}

@end