//
//  MR0x02ViewController.m
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2021/4/15.
//  Copyright © 2021 Matt Reach's Awesome FFmpeg Tutotial. All rights reserved.
//

#import "MR0x02ViewController.h"
#import <FFmpegTutorial/MRThread.h>
#import "MRDragView.h"
#import "MRUtil.h"

@interface MR0x02ViewController ()

@property (assign) IBOutlet NSTextView *textView;
@property (strong) NSMutableArray *array;
@property (strong) NSLock *lock;

@end

@implementation MR0x02ViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.lock = [[NSLock alloc] init];
}
- (void)doCancel:(NSMutableArray *)arr
{
    if ([arr count] == 0) {
        return;
    }
    MRThread *t = [arr lastObject];;
    [t cancel];
    [t join];
    [arr removeLastObject];
    double delay = arc4random() % 1000 / 10000.0;
    [self performSelector:@selector(doCancel:) withObject:arr afterDelay:delay];
    
    NSString *msg = nil;
    [self.lock lock];
    msg = [msg_buff componentsJoinedByString:@"\n"];
    [self.lock unlock];
    self.textView.string = msg;
}

static NSMutableArray* msg_buff = nil;

- (void)appendMsg:(NSString *)msg
{
    [self.lock lock];
    if (msg_buff == nil) {
        msg_buff = [NSMutableArray array];
    }
    
    if ([msg_buff count] > 25) {
        [msg_buff removeObjectAtIndex:0];
    }
    [msg_buff addObject:msg];
    [self.lock unlock];
}

- (IBAction)go:(NSButton *)sender
{
    NSMutableArray *arr = [NSMutableArray array];
    static int count = 0;
    for (int i = 0; i < 100; i++) {
        int n = count++;
        MRThread *t = [[MRThread alloc] initWithBlock:^{
            while (![[NSThread currentThread] isCancelled]) {
                int s = 1 + arc4random() % 10;
                usleep(1000 * s);
                NSString *msg = [NSString stringWithFormat:@"%@ sleep %d ms",[[NSThread currentThread]name],s];
                [self appendMsg:msg];
            }
        }];
        t.name = [NSString stringWithFormat:@"%d",n];
        [arr addObject:t];
        [t start];
    }
    [self performSelector:@selector(doCancel:) withObject:arr afterDelay:0.05];
}

@end
